#!/usr/bin/perl
# This program forks children to handle a number of slow tasks.  It
# uses POE::Filter::Reference so the child tasks can send back
# arbitrary Perl data.  The constant MAX_CONCURRENT_TASKS limits the
# number of forked processes that can run at any given time.
use warnings;
use strict;
use v5.32.0;
use Data::Dumper;

use POE qw(Wheel::Run Filter::Reference Wheel::ReadWrite Component::Client::WebSocket);
use JSON::MaybeXS;
use Try::Tiny;
use Cwd 'abs_path';
use Path::Tiny;

# Paths
my $script_path = abs_path($0);
my $path_obj = path($script_path);
my $base_path = $path_obj->parent->parent;
my $home = $ENV{'HOME'};
my $basedir = "$home/.tmp/gdax_runner";
my $redis_config = "$basedir/redis.conf";
my $nginx_config = "$basedir/nginx.conf";

# Capture ctrl-c
$SIG{INT} = \&killall;
my $halt = 0;
my $worker_count = 3;

sub killall {
    $SIG{INT} = \&killall;
    $halt = 1;
    POE::Kernel->post('main','shutdown');
}

# Global objects
my $json        =   JSON::MaybeXS->new(utf8 => 0);
my $cache       =   {
    currency_list   =>  [],
    last_update     =>  time-10000,
    sub_template    =>  {
        'type'      =>  'subscribe',
        'channels'  =>  [
            {
                'name'          =>  'full',
                'product_ids'   =>  []
            }
        ]
    }
};

# Start the session that will manage all the children.  The _start and
# next_task events are handled by the same function.
POE::Session->create(
    inline_states => {
        _start              =>  \&start,
        new_worker          =>  \&new_worker,
        task_result         =>  \&handle_task_result,
        task_stdout         =>  \&handle_task_stdout,
        task_stderr         =>  \&handle_task_stderr,
        process_market_data =>  \&process_market_data,
        sig_child           =>  \&sig_child,
        shutdown            =>  \&shutdown,
        exit_process        =>  \&exit_process,
        start_redis         =>  \&start_redis,
        start_nginx         =>  \&start_nginx,
    },
    heap => {
        workers => 0,
    }
);

sub start {
    my ($kernel,$session,$heap) =  @_[KERNEL, SESSION, HEAP];
    init_currency_poller();
    $kernel->call($session, 'start_redis');
    $kernel->call($session, 'start_nginx');
    $kernel->alias_set('main');
    $kernel->delay('new_worker' => 10);
}

sub shutdown {
    my ($kernel,$heap) =  @_[KERNEL, HEAP];
    foreach my $process_id (keys %{$heap->{task}}) {
        my $target = $heap->{task}->{$process_id};
        if (ref($target) eq 'HASH' && defined $target->{pid}) { 
            # Note EVERYTHING will exit with '1' except redis, fuck you redis.
            kill 9,$target->{pid};
        }
    }
    # Make sure to kill the nginx as its a pest.
    `killall nginx`;
    sleep(5);
    do { exit };
}

sub exit_process {
    my ($kernel,$heap,$code) =  @_[KERNEL, HEAP, ARG0];
    if (!defined $code) { $code = 1 }
    exit $code;
}

sub start_redis {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    my $task = POE::Wheel::Run->new(
        Program      => 'redis-server',
        ProgramArgs  => [$redis_config],
        StdoutFilter => POE::Filter::Line->new(),
        StdoutEvent  => "task_stdout",
        StderrEvent  => "task_stderr",
        CloseEvent   => "task_done",
    );

    $heap->{task}->{$task->ID} = { obj=>$task, pid=>$task->PID, id=>$task->ID, rx=>0 };
    $heap->{task}->{$task->PID} = $task->ID;

    $kernel->sig_child($task->PID, "sig_child");
}

sub start_nginx {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    my $task = POE::Wheel::Run->new(
        Program      => 'nginx',
        ProgramArgs  => ['-c',$nginx_config],
        StdoutFilter => POE::Filter::Line->new(),
        StdoutEvent  => "task_stdout",
        StderrEvent  => "task_stderr",
        CloseEvent   => "task_done",
    );

    $heap->{task}->{$task->ID} = { obj=>$task, pid=>$task->PID, id=>$task->ID, rx=>0 };
    $heap->{task}->{$task->PID} = $task->ID;

    $kernel->sig_child($task->PID, "sig_child");
}

sub new_worker {
    my ($kernel, $heap) = @_[KERNEL, HEAP];

    if ($halt) { return }

    if ($heap->{workers} >= $worker_count) { return }
    elsif (!-e "$basedir/subscription.json") { 
        $kernel->delay('new_worker' => 10);
        return;
    }
    else {
        $kernel->delay('new_worker' => 10);
    }

    $heap->{workers}++;

    my $rust_path = "$base_path/gdax_portal/target/release/gdax_portal";

    my $task = POE::Wheel::Run->new(
        Program      => 'sh -c "'.$rust_path.'"',
        StdoutFilter => POE::Filter::Line->new(),
        StdoutEvent  => "task_stdout",
        StderrEvent  => "task_stderr",
        CloseEvent   => "task_done",
    );

    $heap->{task}->{$task->ID} = { obj=>$task, pid=>$task->PID, id=>$task->ID, rx=>0 };
    $heap->{task}->{$task->PID} = $task->ID;

    $kernel->sig_child($task->PID, "sig_child");
}


# Handle information returned from the task.  Since we're using
# POE::Filter::Reference, the $result is however it was created in the
# child process.  In this sample, it's a hash reference.
sub handle_task_stdout {
    my ($kernel,$heap,$stdout,$wheel_id) = @_[KERNEL,HEAP,ARG0,ARG1];

    my @dataset = split(/\s+/,$stdout,5);

    if (defined($dataset[3]) && $dataset[2] eq 'ERROR') {
        my $pid = $heap->{task}->{$wheel_id}->{pid};
        kill 1,$pid;
        say "worker($wheel_id) Kill";
    }

     say "($wheel_id): $stdout";
}

# Catch and display information from the child's STDERR.  This was
# useful for debugging since the child's warnings and errors were not
# being displayed otherwise.
sub handle_task_stderr {
    my ($kernel,$heap,$result,$wheel_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    print "Debug($wheel_id): $result\n";
}

sub handle_task_result {
    my ($kernel,$heap,$result,$wheel_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    say "Task ended($wheel_id), restarting";

    my $pid = delete $heap->{task}->{$wheel_id}->{pid};
    delete $heap->{task}->{$pid};

    $heap->{workers}--;

    $kernel->yield('new_worker');
}

# Detect the CHLD signal as each of our children exits.
sub sig_child {
    my ($kernel,$heap, $sig, $pid, $exit_val) = @_[KERNEL,HEAP, ARG0, ARG1, ARG2];

    my $wid = delete $heap->{task}->{$pid};
    my $rxc = $heap->{task}->{$wid}->{rx};
    delete $heap->{task}->{$wid};

    $heap->{workers}--;

    say "Sig($wid) received on worker, pid $pid (rx: $rxc)";

    $kernel->yield('new_worker');
}

sub init_currency_poller() {
    POE::Session->create(
        inline_states => {
            '_start'      =>  sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];

                # Create any objects we will have to use
                $heap->{cache}->{status_channel}    =
                    encode_json({
                        'type'      =>  'subscribe',
                        'channels'  =>  [{ 'name'   =>  'status'}]
                    });
                $heap->{cache}->{currency_list}     =
                    [];
                $heap->{stash}->{last_update}       =
                    0;

                # Create an alias so people know who we are
                $kernel->alias_set('currency_poller');
                # Stage 1 start a scheduler
                $kernel->yield('scheduler');
                # Stage 2 initilize the websocket session
                $kernel->yield('connect_websocket');
            },
            'connect_websocket' => sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];
                $heap->{ws} = POE::Component::Client::WebSocket->new(
                    'wss://ws-feed.pro.coinbase.com'
                );
                $heap->{ws}->connect;
            },
            'scheduler'   =>  sub {
                my ($kernel,$heap)  =   @_[KERNEL,HEAP];

                # Create a 1 second scheduler to enforce longevity
                $kernel->delay('scheduler' => 1);
            },
            'websocket_handshake' =>  sub {
                my ($kernel,$heap)  =   @_[KERNEL,HEAP];
                $heap->{ws}->send($heap->{cache}->{status_channel});
                $heap->{connection}  = 1;
            },
            'websocket_disconnected' => sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];
                $heap->{connection}  = 0;
                $kernel->yield('connect_websocket');
            },
            'websocket_read' => sub {
                my ($kernel,$heap,$read) = @_[KERNEL,HEAP,ARG0];

                my $packet          =   undef;
                my $currency_list   =   [];

                # Try to decode the json packet first
                try {
                    $packet = $json->decode($read);
                };

                # Initial validation because we do not trust these fucks
                if (
                    !defined ($packet)
                    || ref($packet) ne 'HASH'
                    || !defined($packet->{'type'})
                ) {
                    # Wow, spechul;
                    return;
                }

                # Derive the packet type
                my $packet_type     =   $packet->{'type'};

                say "websocket read (type: $packet_type) ";

                # Put this in its own handler TODO
                if ($packet_type eq 'status') {
                    foreach my $currency (@{$packet->{products}}) {
                        my $currency_id = $currency->{id};
                        if ($currency->{status} ne 'online') { next }
                        push(@{$currency_list},$currency->{id});
                    }

                    # Check if the new list is differnet to the old
                    # by comparing, joining and checking them
                    my @listA       =
                        sort { $a cmp $b } @{$cache->{currency_list}};
                    my @listB       =
                        sort { $a cmp $b } @{$currency_list};

                    my $listAJoined =
                        join('',@listA);
                    my $listBJoined =
                        join('',@listB);

                    if ($listAJoined ne $listBJoined) {
                        $heap->{cache}->{last_update}   =   time;
                        $cache->{currency_list} = $currency_list;
                        $kernel->yield('alert_currency_list_change');
                    }
                }
            },
            'alert_currency_list_change' => sub {
                my ($kernel,$heap) = @_[KERNEL,HEAP];
                say STDERR time." Currency list updated";
                $cache->{sub_template}->{channels}->[0]->{product_ids} = $cache->{currency_list};
                open(my $fh,'>',"$basedir/subscription.json");
                print $fh $json->encode($cache->{sub_template});
                close($fh);
            },
            'active_currency_list' => sub {
                my ($kernel,$sender,$heap) = @_[KERNEL,SENDER,HEAP];

                $kernel->post($sender->ID,'active_currency_list',$heap->{cache}->{currency_list});
            }
        },
    );
}

# Run until there are no more tasks.
$poe_kernel->run();
exit 0;
