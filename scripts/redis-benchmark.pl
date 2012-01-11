#!/usr/bin/env perl

use warnings;
use strict;
use Benchmark qw/:all/;
use lib 'lib';
use Redis;
use RedisDB;

my $rd_tcp = Redis->new(encoding => undef);
my $rd_unx = Redis->new(sock => $ENV{REDIS_PATH}, encoding => undef);
my $db_tcp = RedisDB->new;
my $db_unx = RedisDB->new(path => $ENV{REDIS_PATH});

my $i    = 0;
my $big  = 'a' x 16_000;
my @many = (1 .. 1000);


timethese(
  -5,
  { 'rd_tcp_ping' => sub { $rd_tcp->ping },
    'rd_unx_ping' => sub { $rd_unx->ping },
    'db_tcp_ping' => sub { $db_tcp->ping },
    'db_unx_ping' => sub { $db_unx->ping },
  }
);

timethese(
  -5,
  { 'rd_tcp_set' => sub { $rd_tcp->set('foo', $i++) },
    'rd_unx_set' => sub { $rd_unx->set('foo', $i++) },
    'db_tcp_set' => sub { $db_tcp->set('foo', $i++) },
    'db_unx_set' => sub { $db_unx->set('foo', $i++) },
  }
);

timethese(
  -5,
  { 'rd_tcp_set_big' => sub { $rd_tcp->set('foo-big', $big) },
    'rd_unx_set_big' => sub { $rd_unx->set('foo-big', $big) },
    'db_tcp_set_big' => sub { $db_tcp->set('foo-big', $big) },
    'db_unx_set_big' => sub { $db_unx->set('foo-big', $big) },
  }
);

timethese(
  -5,
  { 'rd_tcp_get' => sub { $rd_tcp->set('foo') },
    'rd_unx_get' => sub { $rd_unx->set('foo') },
    'db_tcp_get' => sub { $db_tcp->set('foo') },
    'db_unx_get' => sub { $db_unx->set('foo') },
  }
);

timethese(
  -5,
  { 'rd_tcp_get_big' => sub { $rd_tcp->set('foo-big') },
    'rd_unx_get_big' => sub { $rd_unx->set('foo-big') },
    'db_tcp_get_big' => sub { $db_tcp->set('foo-big') },
    'db_unx_get_big' => sub { $db_unx->set('foo-big') },
  }
);

timethese(
  -5,
  { 'rd_tcp_incr' => sub { $rd_tcp->incr('counter') },
    'rd_unx_incr' => sub { $rd_unx->incr('counter') },
    'db_tcp_incr' => sub { $db_tcp->incr('counter') },
    'db_unx_incr' => sub { $db_unx->incr('counter') },
  }
);

timethese(
  -5,
  { 'rd_tcp_lpush' => sub { $rd_tcp->lpush('mylist', 'bar') },
    'rd_unx_lpush' => sub { $rd_unx->lpush('mylist', 'bar') },
    'db_tcp_lpush' => sub { $db_tcp->lpush('mylist', 'bar') },
    'db_unx_lpush' => sub { $db_unx->lpush('mylist', 'bar') },
  }
);

timethese(
  -5,
  { 'rd_tcp_lpush_many' => sub { $rd_tcp->lpush('mylist-m', @many) },
    'rd_unx_lpush_many' => sub { $rd_unx->lpush('mylist-m', @many) },
    'db_tcp_lpush_many' => sub { $db_tcp->lpush('mylist-m', @many) },
    'db_unx_lpush_many' => sub { $db_unx->lpush('mylist-m', @many) },
  }
);

timethese(
  -5,
  { 'rd_tcp_lpop' => sub { $rd_tcp->lpop('mylist') },
    'rd_unx_lpop' => sub { $rd_unx->lpop('mylist') },
    'db_tcp_lpop' => sub { $db_tcp->lpop('mylist') },
    'db_unx_lpop' => sub { $db_unx->lpop('mylist') },
  }
);
