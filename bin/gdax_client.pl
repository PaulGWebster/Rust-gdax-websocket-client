#!/usr/bin/env perl

use v5.30.0;

use warnings;
use strict;
use utf8;
use experimental 'signatures';
use Data::Dumper;

use Redis::Fast;
use JSON::MaybeXS;

my $json = JSON::MaybeXS->new(utf8 => 0);
my $redis = Redis::Fast->new(sock => '/tmp/redis.sock');
my $redis_retrieve = Redis::Fast->new(sock => '/tmp/redis.sock');
my $check_dup = {};
my $last_int = {};
my $raw_json;
my $product_list = product_list_sync();

$redis->subscribe(
    @{$product_list},
    sub {
         my ($message, $topic, $subscribed_topic) = @_;
         proc_publish(@_);  
    }
);

sub proc_publish($message,$topic,$subscribed_topic,@other) {
    if ($check_dup->{$topic} >= $message) { return }
    $check_dup->{$topic} = $message;
    my $int_diff = ($message - $last_int->{$topic});
    my $last_int_x = $last_int->{$topic};
    if ($int_diff > 1) { say "WARNING: $int_diff difference! ($last_int_x:$message:$topic)" }
    $last_int->{$topic} = $message;
    my $json = $redis_retrieve->get(join(':',$topic,$message));
#    say $json;
}

sub product_list_sync () {
    local $/;
    open(my $fh,'<','/tmp/subscription.json');
    $raw_json = <$fh>;
    close($fh);
    my $subscribe_packet = $json->decode($raw_json);
    my $return_list = $subscribe_packet->{channels}->[0]->{product_ids};
    foreach my $currency (@{$return_list}) {
        if (!$check_dup->{$currency}) { $check_dup->{$currency} = 0; $last_int->{$currency} = 0 }
    }
    return $return_list;
}

$redis->wait_for_messages(10) while 1;
