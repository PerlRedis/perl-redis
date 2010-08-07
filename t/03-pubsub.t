#!perl

use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use Redis;

my %got;
my $pub = Redis->new();
my $sub = Redis->new();

is($pub->publish('aa', 'v1'), 0, "No subscribers to 'aa' topic");

## Basic pubsub
my $sub_cb = sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" };
$sub->subscribe('aa', 'bb', $sub_cb);
is($pub->publish('aa', 'v1'), 1, "Delivered to 1 subscriber of topic 'aa'");

is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
cmp_deeply(\%got, {'aa' => 'v1:aa'}, "... for the expected topic, 'aa'");

my $sub_cb2 = sub { my ($v, $t, $s) = @_; $got{"2$s"} = uc("$v:$t") };
$sub->subscribe('aa', $sub_cb2);
is($pub->publish('aa', 'v1'), 1, "Delivered to 1 subscriber of topic 'aa'");

is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
cmp_deeply(
  \%got,
  {'aa' => 'v1:aa', '2aa' => 'V1:AA'},
  "... for the expected topic, 'aa', with two handlers"
);


## Trick subscribe with other messages
my $psub_cb = sub { my ($v, $t, $s) = @_; $got{$s} = "$v:$t" };
%got = ();
is($pub->publish('aa', 'v2'), 1, "Delivered to 1 subscriber of topic 'aa'");
$sub->psubscribe('a*', 'c*', $psub_cb);
cmp_deeply(
  \%got,
  {'aa' => 'v2:aa', '2aa' => 'V2:AA'},
  '... received message while processing psubscribe(), two handlers'
);

is($pub->publish('aa', 'v3'), 2, "Delivered to 2 subscriber of topic 'aa'");
is($sub->wait_for_messages(1), 2, '... yep, got the expected 2 messages');
cmp_deeply(
  \%got,
  {'aa' => 'v3:aa', 'a*' => 'v3:aa', '2aa' => 'V3:AA'},
  "... for the expected subs, 'aa' and 'a*', three handlers total"
);

## Test subscribe/psubscribe diffs
%got = ();
is($pub->publish('aaa', 'v4'), 1, "Delivered to 1 subscriber of topic 'aaa'");
is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
cmp_deeply(\%got, {'a*' => 'v4:aaa'}, "... for the expected sub, 'a*'");


## Subscriber mode status
is($sub->is_subscriber, 4, 'Current subscriber has 4 subscriptions active');
is($pub->is_subscriber, 0, '... the publisher has none');


## Unsubscribe
$sub->unsubscribe('xx', sub { });
is($sub->is_subscriber, 4,
  "No match to our subscriptions, unsubscribe doesn't change active count");

$sub->unsubscribe('aa', $sub_cb);
is($sub->is_subscriber, 4,
  "unsubscribe ok, active count is still 4, another handler is alive");

$sub->unsubscribe('aa', $sub_cb2);
is($sub->is_subscriber, 3,
  "unsubscribe done, active count is now 3, both handlers are done");

$pub->publish('aa', 'v5');
%got = ();
is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
cmp_deeply(\%got, {'a*', 'v5:aa'}, "... for the expected key, 'a*'");

$sub->unsubscribe('a*', $psub_cb);
is($sub->is_subscriber, 3,
  "unsubscribe with topic wildcard failed, active count is now 3");

$pub->publish('aa', 'v6');
%got = ();
is($sub->wait_for_messages(1), 1, '... yep, got the expected 1 message');
cmp_deeply(\%got, {'a*', 'v6:aa'}, "... for the expected key, 'a*'");

$sub->unsubscribe('bb', $sub_cb);
is($sub->is_subscriber, 2, "unsubscribe with 'bb' ok, active count is now 2");

$sub->punsubscribe('a*', $psub_cb);
is($sub->is_subscriber, 1,
  "punsubscribe with 'a*' ok, active count is now 1");

is($pub->publish('aa', 'v6'), 0, "Publish to 'aa' now gives 0 deliveries");
%got = ();
is($sub->wait_for_messages(1), 0, '... yep, no messages delivered');
cmp_deeply(\%got, {}, '... and an empty messages recorded set');

is($sub->is_subscriber, 1, 'Still some pending subcriptions active');
throws_ok sub { $sub->info },
  qr/Cannot use command 'INFO' while in SUBSCRIBE mode/,
  '... still an error to try commands in subscribe mode';
$sub->punsubscribe('c*', $psub_cb);
is($sub->is_subscriber, 0, '... but none anymore');

lives_ok sub { $sub->info },
  'Other commands ok after we leave subscriber_mode';


## And we are done
done_testing();
