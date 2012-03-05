#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Time::HiRes qw(gettimeofday tv_interval);
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }


subtest 'Command without connection, no reconnect' => sub {
  ok(my $r = Redis->new(reconnect => 0, server => $srv),
    'connected to our test redis-server');
  ok($r->quit, 'close connection to the server');

  like(
    exception { $r->set(reconnect => 1) },
    qr{Not connected to any server},
    'send ping without reconnect',
  );
};


subtest 'Command without connection or timeout, with reconnect' => sub {
  ok(my $r = Redis->new(reconnect => 2, server => $srv),
    'connected to our test redis-server');

  ok($r->quit, 'close connection to the server');
  ok($r->set(reconnect => $$), 'send command with reconnect');

  ## Redis will timeout clients after 100 internal server loops, at
  ## least 10 seconds (even with a timeout 1 on the config) so we sleep
  ## a bit more hoping the timeout did happen. Not perfect, patches
  ## welcome
  sleep(11);
  is($r->get('reconnect'), $$, 'reconnect with read errors before write');
};


subtest 'INFO commands with extra logic triggers reconnect' => sub {
  ok(my $r = Redis->new(reconnect => 2, server => $srv),
     'connected to our test redis-server');

  ok($r->quit, 'close connection to the server');

  my $info = $r->info;
  is(ref $info, 'HASH', 'reconnect on INFO command');
};


subtest 'KEYS commands with extra logic triggers reconnect' => sub {
  ok(my $r = Redis->new(reconnect => 2, server => $srv),
     'connected to our test redis-server');

  ok($r->flushdb, 'delete all keys');
  ok($r->set(reconnect => $$), 'set known key');

  ok($r->quit, 'close connection to the server');

  my @keys = $r->keys('*');
  is_deeply(\@keys, ['reconnect'], 'reconnect on KEYS command');
};


subtest "Bad commnands don't trigger reconnect" => sub {
  ok(my $r = Redis->new(reconnect => 2, server => $srv),
    'connected to our test redis-server');

  my $prev_sock = "$r->{sock}";
  like(
    exception { $r->set(bad => reconnect => 1) },
    qr{ERR wrong number of arguments for 'set' command},
    'Bad commands still die',
  );
  is("$r->{sock}", $prev_sock, "... and don't trigger a reconnect");
};


subtest "Reconnect gives up after timeout" => sub {
  ok(my $r = Redis->new(reconnect => 3, server => $srv),
    'connected to our test redis-server');
  $c->();    ## Make sure the server is dead

  my $t0 = [gettimeofday];
  like(
    exception { $r->set(reconnect => 1) },
    qr{Could not connect to Redis server at},
    'Eventually it gives up and dies',
  );
  ok(tv_interval($t0) > 3, '... minimum value for the reconnect reached');
};


done_testing();
