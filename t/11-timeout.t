#!perl

use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisTimeoutServer;
use Errno qw(ETIMEDOUT EWOULDBLOCK);
use POSIX qw(strerror);

subtest 'server replies quickly enough' => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(0);
    my $redis = Redis->new(server => '127.0.0.1:' . $server->port, read_timeout => 1);
    ok($redis);
    my $res = $redis->get('foo');;
    is $res, 42;
};

subtest "server doesn't replies quickly enough" => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(10);
    my $redis = Redis->new(server => '127.0.0.1:' . $server->port, read_timeout => 1);
    ok($redis);
    my $msg1 = "Error while reading from Redis server: " . strerror(ETIMEDOUT);
    my $msg2 = "Error while reading from Redis server: " . strerror(EWOULDBLOCK);
    like(
         exception { $redis->get('foo'); },
         qr/$msg1|$msg2/,
         "the code died as expected",
        );
};

done_testing;
