#!/usr/bin/perl

use warnings;
use strict;

use Test::More tests => 4;

use lib 'lib';

BEGIN {
	use_ok( 'Redis' );
}

ok( my $o = Redis->new(), 'new' );

ok( $o->ping, 'ping' );

ok( $o->quit, 'quit' );
