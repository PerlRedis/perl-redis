#!perl

use strict;
use warnings;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::SpawnRedisTimeoutServer;
use Errno qw(ETIMEDOUT EWOULDBLOCK);
use POSIX qw(strerror);
use Carp;
use IO::Socket::INET;
use Test::TCP;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

subtest 'server replies quickly enough' => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(0);
    my $redis = Redis->new(server => '127.0.0.1:' . $server->port,
                           read_timeout => 1,
                           ssl => SSL_AVAILABLE,
                           SSL_verify_mode => 0);
    ok($redis);
    my $res = $redis->get('foo');;
    is $res, 42, "the code didn't died, as expected";
};

subtest "server doesn't replies quickly enough" => sub {
    my $server = Test::SpawnRedisTimeoutServer::create_server_with_timeout(10);
    my $redis = Redis->new(server => '127.0.0.1:' . $server->port,
                           read_timeout => 1,
                           ssl => SSL_AVAILABLE,
                           SSL_verify_mode => 0);
    ok($redis);
    like(
         exception { $redis->get('foo'); },
         qr/Error while reading from Redis server:/,
         "the code died as expected",
        );
    ok($! == ETIMEDOUT || $! == EWOULDBLOCK);
};

subtest "server doesn't respond at connection (cnx_timeout)" => sub {
  SKIP: {
    skip "This subtest is failing on some platforms", 4;
	my $server = Test::TCP->new(code => sub {
            my $port = shift;

            my %args = (
                Listen    => 1,
                LocalPort => $port,
                LocalAddr => '127.0.0.1',
            );

            my $socket_class = 'IO::Socket::INET';

            if ( SSL_AVAILABLE ) {
                $socket_class = 'IO::Socket::SSL';

                $args{SSL_cert_file} = 't/stunnel/cert.pem';
                $args{SSL_key_file}  = 't/stunnel/key.pem';
            }

			my $sock = $socket_class->new(%args) or croak "fail to listen on port $port";
			while(1) {
				sleep(1);
			};
	});

    my $redis;
    my $start_time = time;
    isnt(
         exception { $redis = Redis->new(server => '127.0.0.1:' . $server->port,
                                         cnx_timeout => 1,
                                         ssl => SSL_AVAILABLE, SSL_verify_mode => 0); },
         undef,
         "the code died",
        );
    ok(time - $start_time >= 1, "gave up late enough");
    ok(time - $start_time < 5, "gave up soon enough");
    ok(!$redis, 'redis was not set');
  }
};

done_testing;

