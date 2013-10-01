#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use FindBin qw($Bin);
use lib "$Bin/tlib";
use Test::SpawnFakeRedis;
use Redis;
use POSIX qw(ETIMEDOUT strerror);

my ( $kill_server, $address ) = redis();

END {
    $kill_server->() if $kill_server;
    exit 0;    # don't let a bad status sometimes kill this test
}

ok( my $o = Redis->new( server => $address, timeout => 2 ),
    'We should be able to connect to our Redis server with a timeout value'
);
ok( $o->ping, '... and ping it' );
# Commands operating on string values

my $etimedout = strerror(ETIMEDOUT);

like(
    exception {
        $o->set( foo => 'bar' )
    },
    qr/^Error while reading from Redis server: $etimedout/,
    '... and a read timeout should throw an exception'
);
done_testing;
