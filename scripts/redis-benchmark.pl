#!/usr/bin/perl

use warnings;
use strict;
use Benchmark qw/:all/;
use lib 'lib';
use Redis;

my $r = Redis->new;

timethese( 100000, {
	'ping'  => sub { $r->ping },
	'set'   => sub { $r->set( 'bench-' . rand(), rand() ) },
	'get'   => sub { $r->get( 'bench-' . rand() ) },
	'incr'  => sub { $r->incr( 'bench-incr' ) },
	'lpush' => sub { $r->lpush( 'bench-lpush', rand() ) },
	'lpop'  => sub { $r->lpop( 'bench-lpop' ) },
});
