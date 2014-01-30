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
use Test::TCP;

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

subtest "server doesn't respond at connection (cnx_timeout)" => sub {
	my $server = Test::TCP->new(code => sub {
			my $port = shift;
			my $sock = IO::Socket::INET->new(Listen => 1, LocalPort => $port, Proto => 'tcp', LocalAddr => '127.0.0.1') or croak "fail to listen on port $port";
			while(1) {
				sleep(1);
			};
	});

    my $redis;
    my $start_time = time;
    isnt(
         exception { $redis = Redis->new(server => '127.0.0.1:' . $server->port, cnx_timeout => 1); },
         undef,
         "the code died",
        );
    ok(time - $start_time >= 1, "gave up late enough");
    ok(time - $start_time < 5, "gave up soon enough");
    ok(!$redis, 'redis was not set');

};

done_testing;

