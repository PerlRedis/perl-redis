#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 6;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

ok( $o->set( foo => 'bar' ), 'set foo' );
cmp_ok( $o->get( 'foo' ), 'eq', 'bar', 'get foo' );

ok( $o->quit, 'quit' );
