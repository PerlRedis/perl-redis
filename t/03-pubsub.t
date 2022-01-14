#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Test::Deep;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer qw( redis reap );

use constant DEFAULT_DELAY => 5;
use constant SSL_AVAILABLE => eval { require IO::Socket::SSL } || 0;

my ($c, $t, $srv) = redis();
END {
  $c->() if $c;
  $t->() if $t;
}

my $use_ssl = $t ? SSL_AVAILABLE : 0;

{
my $r = Redis->new(server => $srv,
                   ssl => $use_ssl,
                   SSL_verify_mode => 0);
eval { $r->publish( 'aa', 'v1' ) };
plan 'skip_all' => "pubsub not implemented on this redis server"  if $@ && $@ =~ /unknown command/;
}

my ($another_kill_switch, $yet_another_kill_switch);
my ($another_kill_switch_stunnel, $yet_another_kill_switch_stunnel);
END {
  $_ and $_->() for ($another_kill_switch,
                     $yet_another_kill_switch,
                     $another_kill_switch_stunnel,
                     $yet_another_kill_switch_stunnel)
}

subtest 'basics' => sub {
  my %got;
  ok(my $pub = Redis->new(server => $srv,
                          ssl => $use_ssl,
                          SSL_verify_mode => 0), 'connected to our test redis-server (pub)');
  ok(my $sub = Redis->new(server => $srv,
                          ssl => $use_ssl,
                          SSL_verify_mode => 0), 'connected to our test redis-server (sub)');

  is($pub->publish('aa', 'v1'), 0, "No subscribers to 'aa' topic");

  my $db_size = -1;
  $sub->dbsize(sub { $db_size = $_[0] });


  ## Basic pubsub
  my $sub_cb = sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" };
  $sub->subscribe('aa', 'bb', $sub_cb);
  is($pub->publish('aa', 'v1'), 1, "Delivered to 1 subscriber of topic 'aa'");

  is($db_size, 0, 'subscribing processes pending queued commands');

  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { 'aa' => 'v1:aa' }, "... for the expected topic, 'aa'");

  my $sub_cb2 = sub { my ($v, $t, $s) = @_; $got{"2$s"} = uc("$v:$t") };
  $sub->subscribe('aa', $sub_cb2);
  is($pub->publish('aa', 'v1'), 1, "Delivered to 1 subscriber of topic 'aa'");

  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { 'aa' => 'v1:aa', '2aa' => 'V1:AA' }, "... for the expected topic, 'aa', with two handlers");


  ## Trick subscribe with other messages
  my $psub_cb = sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" };
  %got = ();
  is($pub->publish('aa', 'v2'), 1, "Delivered to 1 subscriber of topic 'aa'");
  $sub->psubscribe('a*', 'c*', $psub_cb);
  cmp_deeply(
    \%got,
    { 'aa' => 'v2:aa', '2aa' => 'V2:AA' },
    '... received message while processing psubscribe(), two handlers'
  );

  is($pub->publish('aa', 'v3'), 2, "Delivered to 2 subscriber of topic 'aa'");
  is($sub->wait_for_messages(1), 2, '... yep, got the expected 2 messages');
  cmp_deeply(
    \%got,
    { 'aa' => 'v3:aa', 'a*' => 'v3:aa', '2aa' => 'V3:AA' },
    "... for the expected subs, 'aa' and 'a*', three handlers total"
  );


  ## Test subscribe/psubscribe diffs
  %got = ();
  is($pub->publish('aaa', 'v4'), 1, "Delivered to 1 subscriber of topic 'aaa'");
  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { 'a*' => 'v4:aaa' }, "... for the expected sub, 'a*'");


  ## Subscriber mode status
  is($sub->is_subscriber, 4, 'Current subscriber has 4 subscriptions active');
  is($pub->is_subscriber, 0, '... the publisher has none');


  ## Unsubscribe
  $sub->unsubscribe('xx', sub { });
  is($sub->is_subscriber, 4, "No match to our subscriptions, unsubscribe doesn't change active count");

  $sub->unsubscribe('aa', $sub_cb);
  is($sub->is_subscriber, 4, "unsubscribe ok, active count is still 4, another handler is alive");

  $sub->unsubscribe('aa', $sub_cb2);
  is($sub->is_subscriber, 3, "unsubscribe done, active count is now 3, both handlers are done");

  $pub->publish('aa', 'v5');
  %got = ();
  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { 'a*', 'v5:aa' }, "... for the expected key, 'a*'");

  $sub->unsubscribe('a*', $psub_cb);
  is($sub->is_subscriber, 3, "unsubscribe with topic wildcard failed, active count is now 3");

  $pub->publish('aa', 'v6');
  %got = ();
  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { 'a*', 'v6:aa' }, "... for the expected key, 'a*'");

  $sub->unsubscribe('bb', $sub_cb);
  is($sub->is_subscriber, 2, "unsubscribe with 'bb' ok, active count is now 2");

  $sub->punsubscribe('a*', $psub_cb);
  is($sub->is_subscriber, 1, "punsubscribe with 'a*' ok, active count is now 1");

  is($pub->publish('aa', 'v6'), 0, "Publish to 'aa' now gives 0 deliveries");
  %got = ();
  is($sub->wait_for_messages(1), 0, '... yep, no messages delivered');
  cmp_deeply(\%got, {}, '... and an empty messages recorded set');

  is($sub->is_subscriber, 1, 'Still some pending subcriptions active');
  for my $cmd (qw<ping info keys dbsize shutdown>) {
    like(
      exception { $sub->$cmd },
      qr/Cannot use command '(?i:$cmd)' while in SUBSCRIBE mode/,
      ".. still an error to try \U$cmd\E while in SUBSCRIBE mode"
    );
  }
  $sub->punsubscribe('c*', $psub_cb);
  is($sub->is_subscriber, 0, '... but none anymore');

  is(exception { $sub->info }, undef, 'Other commands ok after we leave subscriber_mode');
};

subtest 'zero_topic' => sub {
  my %got;
  my $pub = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
  my $sub = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);

  my $db_size = -1;
  $sub->dbsize(sub { $db_size = $_[0] });

  my $bad_topic = '0';

  my $sub_cb = sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" };
  $sub->psubscribe("$bad_topic*", 'xx', $sub_cb);
  is($pub->publish($bad_topic, 'vBAD'), 1, "Delivered to 1 subscriber of topic '$bad_topic'");

  is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
  cmp_deeply(\%got, { "$bad_topic*" => "vBAD:$bad_topic" }, "... for the expected topic, '$bad_topic'");
};


subtest 'server is killed while waiting for subscribe' => sub {
  my ($another_kill_switch, $another_kill_switch_stunnel, $another_server) = redis();

  my $pid = fork();
  BAIL_OUT("Fork failed, aborting") unless defined $pid;

  if ($pid) {    ## parent, we'll wait for the child to die quickly
    ok(my $sync = Redis->new(server => $srv,
                             ssl => $use_ssl,
                             SSL_verify_mode => 0), 'connected to our test redis-server (sync parent)');
    BAIL_OUT('Missed sync while waiting for child') unless defined $sync->blpop('wake_up_parent', 4);

    ok($another_kill_switch->(), "pub/sub redis server killed");

    if ($another_kill_switch_stunnel) {
      ok($another_kill_switch_stunnel->(), "stunnel killed");
    }

    note("parent killed pub/sub redis server, signal child to proceed");
    $sync->lpush('wake_up_child', 'the redis-server is dead, do your thing');

    note("parent waiting for child $pid...");
    my $failed = reap($pid, 5);
    if ($failed) {
      fail("wait_for_messages() hangs when the server goes away...");
      kill(9, $pid);
      reap($pid) and fail('... failed to reap the dead child');
    }
    else {
      pass("wait_for_messages() properly detects a server that dies");
    }
  }
  else {    ## child
    my $sync = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $sub  = Redis->new(server => $another_server, ssl => $use_ssl, SSL_verify_mode => 0);
    $sub->subscribe('chan', sub { });

    note("child is ready to test, signal parent to kill our server");
    $sync->lpush('wake_up_parent', 'we are ready on this side, kill the server...');
    die '## Missed sync while waiting for parent' unless defined $sync->blpop('wake_up_child', 4);

    ## This is the test, next wait_for_messages() should not block
    note("now, check wait_for_messages(), should die...");
    like(
      exception { $sub->wait_for_messages(0) },
      qr/EOF from server/,
      "properly died with EOF"
    );
    exit(0);
  }
};

subtest 'server is restarted while waiting for subscribe' => sub {
  my @ret = redis();
  my ($another_kill_switch, $another_kill_switch_stunnel, $another_server) = @ret;
  pop @ret;
  my $port = pop @ret;

  my $pid = fork();
  BAIL_OUT("Fork failed, aborting") unless defined $pid;

  if ($pid) {    ## parent, we'll wait for the child to die quickly

    ok(my $sync = Redis->new(server => $srv,
                             ssl => $use_ssl,
                             SSL_verify_mode => 0), 'PARENT: connected to our test redis-server (sync parent)');
    BAIL_OUT('Missed sync while waiting for child') unless defined $sync->blpop('wake_up_parent', 4);

    ok($another_kill_switch->(), "PARENT: pub/sub redis server killed");

    if ($another_kill_switch_stunnel) {
      ok($another_kill_switch_stunnel->(), "stunnel killed");
    }

    note("PARENT: killed pub/sub redis server, signal child to proceed");
    $sync->lpush('wake_up_child', 'the redis-server is dead, waiting before respawning it');

    sleep DEFAULT_DELAY;

    # relaunch it on the same port
    my ($yet_another_kill_switch, $yet_another_kill_switch_stunnel) = redis(port => $port);
    my $pub = Redis->new(server => $another_server, ssl => $use_ssl, SSL_verify_mode => 0);

    note("PARENT: has relaunched the server...");
    sleep DEFAULT_DELAY;

    is($pub->publish('chan', 'v1'), 1, "PARENT: published and the child is subscribed");

    note("PARENT: waiting for child $pid...");
    my $failed = reap($pid, 5);
    if ($failed) {
      fail("PARENT: wait_for_messages() hangs when the server goes away...");
      kill(9, $pid);
      reap($pid) and fail('PARENT: ... failed to reap the dead child');
    }
    else {
      pass("PARENT: child has properly quit after wait_for_messages()");
    }
    ok($yet_another_kill_switch->(), "PARENT: pub/sub redis server killed");

    if ($yet_another_kill_switch_stunnel) {
      ok($yet_another_kill_switch_stunnel->(), "stunnel killed");
    }
  }
  else {    ## child
    my $sync = Redis->new(server => $srv, ssl => $use_ssl, SSL_verify_mode => 0);
    my $sub  = Redis->new(server => $another_server,
                          ssl => $use_ssl,
                          SSL_verify_mode => 0,
                          reconnect => 10,
                          on_connect => sub { note "CHILD: reconnected (with a 10s timeout)"; }
                         );

    my %got;
    $sub->subscribe('chan', sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" });

    note("CHILD: is ready to test, signal parent to restart our server");
    $sync->lpush('wake_up_parent', 'we are ready on this side, kill the server...');
    die '## Missed sync while waiting for parent' unless defined $sync->blpop('wake_up_child', 4);

    ## This is the test, wait_for_messages() should reconnect to the respawned server
    while (1) {
        note("CHILD: launch wait_for_messages(2), with reconnect...");
        my $r = $sub->wait_for_messages(2);
        $r and last;
        note("CHILD: after 2 sec, nothing yet, retrying");
    }
    note("CHILD: child received the message");
    cmp_deeply(\%got, { 'chan' => 'v1:chan' }, "CHILD: the message is what we want");
    exit(0);
  }
};

## And we are done
done_testing();
