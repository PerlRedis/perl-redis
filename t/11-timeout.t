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
use Carp;
use IO::Socket::INET;

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

subtest "server that doesn't respond at connection (cnx_timeout)" => sub {
	my $socket = IO::Socket::INET->new(Listen => 1, Port => 9999) or die "fail listening 9999";

    my $redis;
	ok ! eval { $redis = Redis->new(server => '127.0.0.1:9999', cnx_timeout => 1); 1 }, 'connexion failed';
	like $@, qr/Operation timed out/, 'timeout detected';
    ok(!$redis, 'redis not setted');

};

subtest "server that doesn't respond at connection (cnx_timeout + read_timeout)" => sub {
	my $socket = IO::Socket::INET->new(Listen => 1, Port => 9999) or die "fail listening 9999";

    my $redis;
	ok ! eval { $redis = Redis->new(server => '127.0.0.1:9999', cnx_timeout => 1, read_timeout => 0.5); 1 }, 'connexion failed';
	like $@, qr/Operation timed out/, 'timeout detected';
    ok(!$redis, 'redis not setted');

};

done_testing;
