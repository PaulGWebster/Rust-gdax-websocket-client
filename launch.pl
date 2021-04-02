#!/usr/bin/env perl

use warnings;
use strict;

use Cwd 'abs_path';
use Path::Tiny;
use File::Path qw(make_path remove_tree);;

# Locate our self in the file system
my $script_path = abs_path($0);
my $path_obj = path($script_path);
my $base_path = $path_obj->parent;
my $home = $ENV{'HOME'};

# Check out the enviroment
my $enviroment_checklist = {
    cargo       =>  0,
    rustc       =>  0,
    perl        =>  0,
    poe         =>  0,
    trytiny     =>  0,
    websocket   =>  0,
    nginx       =>  0,
    redis       =>  0
};

# Check for perl
my $error = 0;
my $perl = $^V;
if ($perl =~ /^v5\.(\d+)\.(\d+)/) {
    my $perl_major = $1;
    my $perl_minor = $2;
    if ($perl_major < 26) {
        say("Our perl version is to old!, version: 5.$perl_major.$perl_minor, required: 5.26.0");
        $error++;
    }
    else {
        say("Yes we have perl version: 5.$perl_major.$perl_minor"); 
        $enviroment_checklist->{perl} = 1;
    }
}
else {
    say $perl;
}

sub say {
    print join(' ',@_)."\n";
}

# Do we have cargo?
my $cargo = `cargo --version`;
if ($cargo =~ m/^cargo ([0-9.]+)/) {
    my $cargo_version = $1;
    say("Yes we have cargo version: $cargo_version");
    $enviroment_checklist->{cargo} = 1;
}
# Do we have rustc?
my $rust = `rustc --version`;
if ($rust =~ m/^rustc ([0-9.]+)/) {
    my $rust_version = $1;
    say("Yes we have rust version: $rust_version");
    $enviroment_checklist->{rustc} = 1;
}
# Do we have POE
my $perl_POE = `perl -e 'use POE'`;
if (!$perl_POE) {
    say "Yes we have POE";
    $enviroment_checklist->{poe} = 1;
} else {
    say "We do not have POE, install it via cpanm POE";
}
# Do we have Try::Tiny
my $perl_tt = `perl -e 'use Try::Tiny'`;
if (!$perl_tt) {
    say "Yes we have Try::Tiny";
    $enviroment_checklist->{trytiny} = 1;
} else {
    say "We do not have Try::Tiny, install it via cpanm Try::Tiny";
}
# do we have POE::Component::WebSocket
my $perl_ws = `perl -e 'use POE::Component::Client::WebSocket'`;
if (!$perl_ws) {
    say "Yes we have POE::Component::Client::WebSocket";
    $enviroment_checklist->{websocket} = 1;
} else {
    say "We do not have POE::Component::Client::WebSocket, install it via cpanm -n POE::Component::Client::WebSocket";
}
# Do we have nginx?
my $nginx = `nginx -v 2>&1 1>/dev/null`;
if ($nginx =~ m/^nginx version: nginx/) {
    say "Yes we have nginx";
    $enviroment_checklist->{nginx} = 1;
} else {
    say "We do not have nginx, please install it using your system management tools, alternatively make sure 'nginx' is availible in path.";
}
# Do we have redis?
my $redis = `redis-server -v`;
if ($redis =~ m/^Redis server v=/) {
    say "Yes we have redis";
    $enviroment_checklist->{redis} = 1;
} else {
    say "We do not have redis, please install it using your system management tools, or make sure 'redis-server' points to the server binary in PATH";
}

# Check we had no failures
foreach my $key (keys %{$enviroment_checklist}) {
    if (!$enviroment_checklist->{$key}) {
        say "Failed check for '$key' aborting";
        exit;
    }
}

# Create a place for us to use a temp directory
my $temp_tree = "$home/.tmp/gdax_runner";
say "Destroying temporay location: $home/.tmp/gdax_runner";
remove_tree($temp_tree);

say "Creating $temp_tree";
make_path($temp_tree);

say "Configuring nginx";
{
    # Read in the nginx template and create a real file
    my $nginx_template = do {
        local $/;
        open(my $fh,'<',"$base_path/etc/nginx.template");
        my $file = <$fh>;
        close($fh);
        $file
    };

    # Swap out the ERROR_PATH and PID_PATH for real values
    my $nginx_error_log = "$temp_tree/nginx_error.log";
    my $nginx_access_log = "$temp_tree/nginx_access.log";
    my $nginx_pid_file = "$temp_tree/nginx.pid";
    $nginx_template =~ s/ERROR_LOG/$nginx_error_log/;
    $nginx_template =~ s/ACCESS_LOG/$nginx_access_log/;
    $nginx_template =~ s/PID_FILE/$nginx_pid_file/;

    # Write the resultant config
    my $nginx_config_path = "$temp_tree/nginx.conf";
    open(my $fh,'>',$nginx_config_path);
    print $fh $nginx_template;
    close($fh);

    # Also copy mime types
    path("$base_path/etc/mime.types")->copy("$temp_tree/mime.types");
}

say "Configuring redis";
{
    # Read in the nginx template and create a real file
    my $redis_template = do {
        local $/;
        open(my $fh,'<',"$base_path/etc/redis.template");
        my $file = <$fh>;
        close($fh);
        $file
    };

    my $unix_socket_path = "$temp_tree/redis.sock";
    my $redis_log_path = "$temp_tree/redis.log";
    $redis_template =~ s/UNIX_SOCKET_PATH/$unix_socket_path/;
    $redis_template =~ s/REDIS_LOGFILE/$redis_log_path/;

    # Write the resultant config
    my $redis_config_path = "$temp_tree/redis.conf";
    open(my $fh,'>',$redis_config_path);
    print $fh $redis_template;
    close($fh);
}

# No failures, assuming the rust enviroment is built we should be able to run

