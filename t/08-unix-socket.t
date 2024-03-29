#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, undef, undef, undef, undef, undef, undef, undef, $sock_temp_file) = redis();
END { $c->() if $c }

my $conn = sub {
  my @args = @_;

  my $r;
  is(
    exception {
      $r = Redis->new(sock => $sock_temp_file, @args);
    },
    undef,
    'Connected to the Redis server ok',
  );

  return $r;
};


subtest 'basic tests' => sub {
  my $r = $conn->();

  ok($r->set(xpto => '42'), '... set command via UNIX ok');
  is($r->get('xpto'), '42', '... and get command ok too');

  is(exception { $r->quit }, undef, 'Connection closed ok');
  like(exception { $r->get('xpto') }, qr!Not connected to any server!, 'Command failed ok, no reconnect',);
};


subtest 'reconnect over UNIX daemon' => sub {
  my $r = $conn->(reconnect => 2);
  ok($r->quit, '... and connection closed ok');

  is(exception { $r->set(xpto => '43') }, undef, 'set command via UNIX ok, reconnected fine');
  is($r->get('xpto'), '43', '... and get command ok too');
};


done_testing();
