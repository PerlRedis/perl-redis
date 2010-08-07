package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use IO::Select;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Data::Dumper;
use Carp qw/confess/;
use Encode;

=head1 NAME

Redis - perl binding for Redis database

=cut

our $VERSION = '1.2001';


=head1 DESCRIPTION

Pure perl bindings for L<http://code.google.com/p/redis/>

This version supports protocol 1.2 or later of Redis available at

L<git://github.com/antirez/redis>

This documentation
lists commands which are exercised in test suite, but
additinal commands will work correctly since protocol
specifies enough information to support almost all commands
with same peace of code with a little help of C<AUTOLOAD>.

=head1 FUNCTIONS

=head2 new

  my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

  my $r = Redis->new( server => '192.168.0.1:6379', debug = 0 );

=cut

sub new {
  my $class = shift;
  my $self  = {@_};

  $self->{debug} ||= $ENV{REDIS_DEBUG};
  $self->{encoding} ||= 'utf8';    ## default to lax utf8

  $self->{server} ||= $ENV{REDIS_SERVER} || '127.0.0.1:6379';
  $self->{sock} = IO::Socket::INET->new(
    PeerAddr => $self->{server},
    Proto    => 'tcp',
  ) || confess("Could not connect to Redis server at $self->{server}: $!");

  $self->{read_size} = 8192;
  $self->{rbuf}      = '';

  $self->{is_subscriber} = 0;
  $self->{subscribers}   = {};

  return bless($self, $class);
}

sub is_subscriber { $_[0]{is_subscriber} }


### we don't want DESTROY to fallback into AUTOLOAD
sub DESTROY { }


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $self = shift;
  my $sock = $self->{sock} || confess("Not connected to any server");
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};

  my $command = $AUTOLOAD;
  $command =~ s/.*://;
  $self->__is_valid_command($command);

  ## PubSub commands use a different answer handling
  if (my ($pr, $unsub) = $command =~ /^(p)?(un)?subscribe$/i) {
    $pr = '' unless $pr;

    my $cb = pop;
    confess("Missing required callback in call to $command(), ")
      unless ref($cb) eq 'CODE';

    my @subs = @_;
    @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
      if $unsub;
    return unless @subs;

    $self->__send_command($command, @subs);

    my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
    return $self->__process_subscription_changes($command, \%cbs);
  }

  $self->__send_command($command, @_);
  return $self->__read_response($command);
}


### Commands with extra logic
sub quit {
  my ($self) = @_;

  $self->__send_command('QUIT');

  delete $self->{rbuf};
  close(delete $self->{sock}) || confess("Can't close socket: $!");

  return 1;
}

sub info {
  my ($self) = @_;
  $self->__is_valid_command('INFO');

  $self->__send_command('INFO');

  my $info = $self->__read_response('INFO');

  return {map { split(/:/, $_, 2) } split(/\r\n/, $info)};
}

sub keys {
  my $self = shift;
  $self->__is_valid_command('KEYS');

  $self->__send_command('KEYS', @_);

  my @keys = $self->__read_response('KEYS', \my $type);
  ## Support redis > 1.26
  return @keys if $type eq '*';

  ## Support redis <= 1.2.6
  return split(/\s/, $keys[0]) if $keys[0];
  return;
}


### PubSub
sub wait_for_messages {
  my ($self, $timeout) = @_;

  my $s = IO::Select->new;
  $s->add($self->{sock});

  my $count = 0;
  while ($s->can_read($timeout)) {
    while ($self->__can_read_sock) {
      my @m = $self->__read_response('WAIT_FOR_MESSAGES');
      $self->__process_pubsub_msg(\@m);
      $count++;
    }
  }

  return $count;
}

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{$subs->{$key}}];
    next if @$cbs;

    delete $subs->{$key};
    push @subs_to_unsubscribe, $sub;
  }

  return @subs_to_unsubscribe;
}

sub __process_subscription_changes {
  my ($self, $cmd, $expected) = @_;
  my $subs = $self->{subscribers};

  while (%$expected) {
    my @m = $self->__read_response($cmd);

    ## Deal with pending PUBLISH'ed messages
    if ($m[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg(\@m);
      next;
    }

    my ($key, $unsub) = $m[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m[1]";
    my $cb = delete $expected->{$key};

    push @{$subs->{$key}}, $cb unless $unsub;

    $self->{is_subscriber} = $m[2];
  }
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = $m->[2] || $sub;

  if (!exists $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return;
  }

  $_->($data, $topic, $sub) for @{$subs->{$cbid}};

  return 1;

}


### Mode validation
sub __is_valid_command {
  my ($self, $cmd) = @_;

  return unless $self->{is_subscriber};
  return if $cmd =~ /^P?(UN)?SUBSCRIBE$/i;
  confess("Cannot use command '$cmd' while in SUBSCRIBE mode, ");
}


### Socket operations
sub __send_command {
  my $self = shift;
  my $cmd  = uc(shift);
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};

  warn "[SEND] $cmd ", Dumper([@_]) if $deb;

  ## Encode command using multi-bulk format
  my $n_elems = scalar(@_) + 1;
  my $buf     = "\*$n_elems\r\n";
  for my $elem ($cmd, @_) {
    my $bin = $enc ? encode($enc, $elem) : $elem;
    $buf .= defined($bin) ? '$' . length($bin) . "\r\n$bin\r\n" : "\$-1\r\n";
  }

  ## Send command, take care for partial writes
  warn "[SEND RAW] $buf" if $deb;
  my $sock = $self->{sock} || confess("Not connected to any server");
  while ($buf) {
    my $len = syswrite $sock, $buf, length $buf;
    confess("Could not write to Redis server: $!")
      unless $len;
    substr $buf, 0, $len, "";
  }

  return;
}

sub __read_response {
  my ($self, $command, $type_r) = @_;

  my ($type, $result) = $self->__read_sock;
  $$type_r = $type if $type_r;

  if ($type eq '-') {
    confess "[$command] $result, ";
  }
  elsif ($type eq '+') {
    return $result;
  }
  elsif ($type eq '$') {
    return if $result < 0;
    return $self->__read_sock($result);
  }
  elsif ($type eq '*') {
    my @list;
    while ($result--) {
      push @list, $self->__read_response($command);
    }
    return @list;
  }
  elsif ($type eq ':') {
    return $result;
  }
  else {
    confess "unknown answer type: $type ($result), ";
  }
}

sub __read_sock {
  my ($self, $len) = @_;
  my $sock = $self->{sock} || confess("Not connected to any server");
  my $enc  = $self->{encoding};
  my $deb  = $self->{debug};
  my $rbuf = \($self->{rbuf});

  my ($data, $type) = ('', '');
  my $read_size = $self->{read_size};
  $read_size = $len + 2 if defined $len && $len + 2 > $read_size;

  while (1) {
    ## Read NN bytes, strip \r\n at the end
    if (defined $len) {
      if (length($$rbuf) >= $len + 2) {
        $data = substr(substr($$rbuf, 0, $len + 2, ''), 0, -2);
        last;
      }
    }
    ## No len, means line more, read until \r\n
    elsif ($$rbuf =~ s/^(.)([^\015\012]*)\015\012//) {
      ($type, $data) = ($1, $2);
      last;
    }

    my $bytes = sysread $sock, $$rbuf, $read_size, length $$rbuf;
    confess("Error while reading from Redis server: $!")
      unless defined $bytes;
    confess("Redis server closed connection") unless $bytes;
  }

  $data = decode($enc, $data) if $enc;
  warn "[RECV] '$type$data'" if $self->{debug};

  return ($type, $data) if $type;
  return $data;
}

sub __can_read_sock {
  my ($self) = @_;
  my $sock   = $self->{sock};
  my $rbuf   = \($self->{rbuf});

  return 1 if $$rbuf;
  __fh_nonblocking($sock, 1);
  my $bytes = sysread $sock, $$rbuf, $self->{read_size}, length $$rbuf;
  __fh_nonblocking($sock, 0);
  return 1 if $bytes;
  return 0;
}


### Copied from AnyEvent::Util
BEGIN {
  *__fh_nonblocking = ($^O eq 'MSWin32')
    ? sub($$) { ioctl $_[0], 0x8004667e, pack "L", $_[1]; }    # FIONBIO
    : sub($$) { fcntl $_[0], F_SETFL, $_[1] ? O_NONBLOCK : 0; };
}


1;

__END__

=head1 Connection Handling

=head2 quit

  $r->quit;

=head2 ping

  $r->ping || die "no server?";

=head1 Commands operating on string values

=head2 set

  $r->set( foo => 'bar' );

  $r->setnx( foo => 42 );

=head2 get

  my $value = $r->get( 'foo' );

=head2 mget

  my @values = $r->mget( 'foo', 'bar', 'baz' );

=head2 incr

  $r->incr('counter');

  $r->incrby('tripplets', 3);

=head2 decr

  $r->decr('counter');

  $r->decrby('tripplets', 3);

=head2 exists

  $r->exists( 'key' ) && print "got key!";

=head2 del

  $r->del( 'key' ) || warn "key doesn't exist";

=head2 type

  $r->type( 'key' ); # = string

=head1 Commands operating on the key space

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );

=head2 randomkey

  my $key = $r->randomkey;

=head2 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=head2 dbsize

  my $nr_keys = $r->dbsize;

=head1 Commands operating on lists

See also L<Redis::List> for tie interface.

=head2 rpush

  $r->rpush( $key, $value );

=head2 lpush

  $r->lpush( $key, $value );

=head2 llen

  $r->llen( $key );

=head2 lrange

  my @list = $r->lrange( $key, $start, $end );

=head2 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=head2 lindex

  $r->lindex( $key, $index );

=head2 lset

  $r->lset( $key, $index, $value );

=head2 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=head2 lpop

  my $value = $r->lpop( $key );

=head2 rpop

  my $value = $r->rpop( $key );

=head1 Commands operating on sets

=head2 sadd

  $r->sadd( $key, $member );

=head2 srem

  $r->srem( $key, $member );

=head2 scard

  my $elements = $r->scard( $key );

=head2 sismember

  $r->sismember( $key, $member );

=head2 sinter

  $r->sinter( $key1, $key2, ... );

=head2 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

=head1 Multiple databases handling commands

=head2 select

  $r->select( $dbindex ); # 0 for new clients

=head2 move

  $r->move( $key, $dbindex );

=head2 flushdb

  $r->flushdb;

=head2 flushall

  $r->flushall;

=head1 Sorting

=head2 sort

  $r->sort("key BY pattern LIMIT start end GET pattern ASC|DESC ALPHA');

=head1 Persistence control commands

=head2 save

  $r->save;

=head2 bgsave

  $r->bgsave;

=head2 lastsave

  $r->lastsave;

=head2 shutdown

  $r->shutdown;

=head1 Remote server control commands

=head2 info

  my $info_hash = $r->info;

=head1 ENCODING

Since Redis knows nothing about encoding, we are forcing utf-8 flag on all data received from Redis.
This change is introduced in 1.2001 version.

This allows us to round-trip utf-8 encoded characters correctly, but might be problem if you push
binary junk into Redis and expect to get it back without utf-8 flag turned on.

=head1 AUTHOR

Dobrica Pavlinusic, C<< <dpavlin at rot13.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-redis at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Redis>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Redis
	perldoc Redis::List
	perldoc Redis::Hash


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Redis>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Redis>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Redis>

=item * Search CPAN

L<http://search.cpan.org/dist/Redis>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2009-2010 Dobrica Pavlinusic, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Redis
