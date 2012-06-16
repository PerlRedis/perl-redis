#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;
use Test::Exception;
use Test::Deep;

my ($c, $srv) = redis();
END { $c->() if $c }

ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server');

sub pipeline_ok {
  my ($desc, @commands) = @_;
  my (@responses, @expected_responses);
  for my $cmd (@commands) {
    my ($method, $args, $expected, $expected_err) = @$cmd;
    push @expected_responses, [$expected, $expected_err];
    $r->$method(@$args, sub { push @responses, [@_] });
  }
  $r->wait_all_responses;

  cmp_deeply(\@responses, \@expected_responses, $desc);
}

pipeline_ok 'single-command pipeline', (
  [set => [foo => 'bar'], 'OK'],
);

pipeline_ok 'pipeline with embedded error', (
  [set  => [clunk => 'eth'], 'OK'],
  [oops => [], undef, q[ERR unknown command 'OOPS']],
  [get  => ['clunk'], 'eth'],
);

pipeline_ok 'keys in pipelined mode', (
  [keys => ['*'], bag(qw<foo clunk>)],
  [keys => [], undef, q[ERR wrong number of arguments for 'keys' command]],
);

pipeline_ok 'info in pipelined mode', (
  [info => [], code(sub { ref $_[0] eq 'HASH' && keys %{ $_[0] } })],
  [info => [qw<oops oops>], undef,
   re(qr/^ERR (?:syntax error|wrong number of arguments for 'info' command)$/)],
);

pipeline_ok 'pipeline with multi-bulk reply', (
  [hmset => [kapow => (a => 1, b => 2, c => 3)], 'OK'],
  [hmget => [kapow => qw<c b a>], [3, 2, 1]],
);

pipeline_ok 'large pipeline', (
  (map { [hset => [zzapp => $_ => -$_], 1] } 1 .. 5000),
  [hmget => [zzapp => (1 .. 5000)], [reverse -5000 .. -1]],
  [del => ['zzapp'], 1],
);

subtest 'synchronous request with pending pipeline' => sub {
  my $clunk;
  is($r->get('clunk', sub { $clunk = $_[0] }), 1, 'queue a request');
  is($r->set('kapow', 'zzapp', sub {}), 1, 'queue another request');
  is($r->get('kapow'), 'zzapp', 'synchronous request has expected return');
  is($clunk, 'eth', 'synchronous request processes pending ones');
};

pipeline_ok 'transaction', (
  [multi => [],                  'OK'],
  [set   => ['clunk' => 'eth'],  'QUEUED'],
  [rpush => ['clunk' => 'oops'], 'QUEUED'],
  [get   => ['clunk'],           'QUEUED'],
  [exec  => [], [
    ['OK', undef],
    [undef, 'ERR Operation against a key holding the wrong kind of value'],
    ['eth', undef],
  ]],
);

subtest 'transaction with error and no pipeline' => sub {
  is($r->multi, 'OK', 'multi');
  is($r->set('clunk', 'eth'), 'QUEUED',  'transactional SET');
  is($r->rpush('clunk', 'oops'), 'QUEUED', 'transactional bad RPUSH');
  is($r->get('clunk'), 'QUEUED', 'transactional GET');
  throws_ok sub { $r->exec },
    qr/\[exec\] ERR Operation against a key holding the wrong kind of value,/,
    'synchronous EXEC dies for intervening error';
};

done_testing();
