package Redis;

# ABSTRACT: Perl binding for Redis database
# VERSION
# AUTHORITY

use warnings;
use strict;

use IO::Socket::INET;
use IO::Socket::UNIX;
use IO::Socket::Timeout;
use IO::Select;
use IO::Handle;
use Fcntl qw( O_NONBLOCK F_SETFL );
use Errno ();
use Data::Dumper;
use Carp;
use Try::Tiny;
use Scalar::Util ();

use Redis::Sentinel;

use constant SSL_AVAILABLE => eval { require IO::Socket::SSL };

use constant WIN32       => $^O =~ /mswin32/i;
use constant EWOULDBLOCK => eval {Errno::EWOULDBLOCK} || -1E9;
use constant EAGAIN      => eval {Errno::EAGAIN} || -1E9;
use constant EINTR       => eval {Errno::EINTR} || -1E9;
use constant ECONNRESET  => eval {Errno::ECONNRESET} || -1E9;

# According to IO::Socket::SSL documentation, 16k is the maximum
# size of an SSL frame and because sysread returns data from only
# a single SSL frame you guarantee this way, that there is no pending
# data.
use constant BUFSIZE     => 16_384;

sub _maybe_enable_timeouts {
    my ($self, $socket) = @_;
    $socket or return;
    defined $self->{read_timeout} || defined $self->{write_timeout}
      or return $socket;
    IO::Socket::Timeout->enable_timeouts_on($socket);
    defined $self->{read_timeout}
      and $socket->read_timeout($self->{read_timeout});
    defined $self->{write_timeout}
      and $socket->write_timeout($self->{write_timeout});
    $socket;
}

sub new {
  my ($class, %args) = @_;
  my $self = bless {}, $class;

  $self->{__buf} = '';
  $self->{debug} = $args{debug} || $ENV{REDIS_DEBUG};

  ## Deal with REDIS_SERVER ENV
  if ($ENV{REDIS_SERVER} && ! defined $args{sock} && ! defined $args{server} && ! defined $args{sentinels}) {
    if ($ENV{REDIS_SERVER} =~ m!^/!) {
      $args{sock} = $ENV{REDIS_SERVER};
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^unix:(.+)!) {
      $args{sock} = $1;
    }
    elsif ($ENV{REDIS_SERVER} =~ m!^(?:tcp:)?(.+)!) {
      $args{server} = $1;
    }
  }

  defined $args{$_}
    and $self->{$_} = $args{$_} for 
      qw(username password on_connect name no_auto_connect_on_new cnx_timeout
         write_timeout read_timeout sentinels_ssl sentinels_username sentinels_password
         sentinels_cnx_timeout sentinels_write_timeout sentinels_read_timeout no_sentinels_list_update);

  $self->{reconnect}     = $args{reconnect} || 0;
  $self->{conservative_reconnect} = $args{conservative_reconnect} || 0;
  $self->{every}         = $args{every} || 1000;

  if (defined $args{sock}) {
    $self->{server} = $args{sock};
    $self->{builder} = sub {
        my ($self) = @_;
        $self->_maybe_enable_timeouts(
            IO::Socket::UNIX->new(
                Peer => $self->{server},
                ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ): () ),
            )
        );
    };
  } elsif ($args{sentinels}) {
      $self->{sentinels} = $args{sentinels};

      ref $self->{sentinels} eq 'ARRAY'
        or croak("'sentinels' param must be an ArrayRef");

      defined($self->{service} = $args{service})
        or croak("Need 'service' name when using 'sentinels'!");

      $self->{builder} = sub {
          my ($self) = @_;
          # try to connect to a sentinel
          my $status;
          foreach my $sentinel_address (@{$self->{sentinels}}) {
              my $sentinel = eval {
                  Redis::Sentinel->new(
                      server    => $sentinel_address,
                      username  => $self->{sentinels_username},
                      password  => $self->{sentinels_password},
                      cnx_timeout   => (   defined $self->{sentinels_cnx_timeout}
                                         ? $self->{sentinels_cnx_timeout}   : 0.1   ),
                      read_timeout  => (   defined $self->{sentinels_read_timeout}
                                         ? $self->{sentinels_read_timeout}  : 1     ),
                      write_timeout => (   defined $self->{sentinels_write_timeout}
                                         ? $self->{sentinels_write_timeout} : 1     ),
                      ssl           => (   defined $self->{sentinels_ssl}
                                         ? $self->{sentinels_ssl}           : 0     ),
                  )
              } or next;
              my $server_address = $sentinel->get_service_address($self->{service});
              defined $server_address
                or $status ||= "Sentinels don't know this service",
                   next;
              $server_address eq 'IDONTKNOW'
                and $status = "service is configured in one Sentinel, but was never reached",
                    next;

              # we found the service, set the server
              $self->{server} = $server_address;

              if (! $self->{no_sentinels_list_update} ) {
                  # move the elected sentinel at the front of the list and add
                  # additional sentinels
                  my $idx = 2;
                  my %h = ( ( map { $_ => $idx++ } @{$self->{sentinels}}),
                            $sentinel_address => 1,
                          );
                  $self->{sentinels} = [
                      ( sort { $h{$a} <=> $h{$b} } keys %h ), # sorted existing sentinels,
                      grep { ! $h{$_}; }                      # list of unknown
                      map { +{ @$_ }->{name}; }               # names of
                      $sentinel->sentinel(                    # sentinels 
                        sentinels => $self->{service}         # for this service
                      )
                  ];
              }

              my $socket_class;

              my %socket_args = (
                  PeerAddr => $server_address,
                  ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ) : () ),
              );

              if (exists $args{ssl} and $args{ssl}) {
                  if ( ! SSL_AVAILABLE ) {
                      croak("IO::Socket::SSL is required for connecting to Redis using SSL");
                  }

                  $self->{ssl}  = 1;
                  $socket_class = 'IO::Socket::SSL';
                  $socket_args{SSL_verify_mode} = $args{SSL_verify_mode} // 1;
              }
              else {
                  $self->{ssl}  = 0;
                  $socket_class = 'IO::Socket::INET';
              }

              return $self->_maybe_enable_timeouts(
                  $socket_class->new(%socket_args)
              );
          }
          croak($status || "failed to connect to any of the sentinels");
      };
  } else {
    $self->{server} = defined $args{server} ? $args{server} : '127.0.0.1:6379';
    $self->{builder} = sub {
        my ($self) = @_;

        my $socket_class;

        my %socket_args = (
            PeerAddr => $self->{server},
            ( $self->{cnx_timeout} ? ( Timeout => $self->{cnx_timeout} ) : () ),
        );

        if (exists $args{ssl} and $args{ssl}) {
            if ( ! SSL_AVAILABLE ) {
                croak("IO::Socket::SSL is required for connecting to Redis using SSL");
            }

            $self->{ssl}  = 1;
            $socket_class = 'IO::Socket::SSL';
            $socket_args{SSL_verify_mode} = $args{SSL_verify_mode} // 1;
        }
        else {
            $self->{ssl}  = 0;
            $socket_class = 'IO::Socket::INET';
        }

        return $self->_maybe_enable_timeouts(
            $socket_class->new(%socket_args)
        );
    };
  }

  $self->{is_subscriber} = 0;
  $self->{subscribers}   = {};

  $self->connect unless $args{no_auto_connect_on_new};

  return $self;
}

sub is_subscriber { $_[0]{is_subscriber} }

sub select {
  my $self = shift;
  my $database = shift;

  croak( "Cannot select an undefined redis database" )
    unless defined $database;
  # don't want to send multiple select() back and forth
  if (!defined $self->{current_database} or $self->{current_database} ne $database) {
    my $ret = $self->__std_cmd('select', $database, @_);
    $self->{current_database} = $database;
    return $ret;
  };
  return "OK"; # emulate redis response as of 3.0.6 just in case anybody cares
}

### we don't want DESTROY to fallback into AUTOLOAD
sub DESTROY { }


### Deal with common, general case, Redis commands
our $AUTOLOAD;

sub AUTOLOAD {
  my $command = $AUTOLOAD;
  $command =~ s/.*://;

  my $method = sub { shift->__std_cmd($command, @_) };

  # Save this method for future calls
  no strict 'refs';
  *$AUTOLOAD = $method;

  goto $method;
}

sub __std_cmd {
  my $self    = shift;
  my $command = shift;

  $self->__is_valid_command($command);

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  # If this is an EXEC command, in pipelined mode, and one of the commands
  # executed in the transaction yields an error, we must collect all errors
  # from that command, rather than throwing an exception immediately.
  my $uc_command = uc($command);
  my $collect_errors = $cb && $uc_command eq 'EXEC';

  if ($uc_command eq 'MULTI') {
      $self->{__inside_transaction} = 1;
  } elsif ($uc_command eq 'EXEC' || $uc_command eq 'DISCARD') {
      delete $self->{__inside_transaction};
      delete $self->{__inside_watch};
  } elsif ($uc_command eq 'WATCH') {
      $self->{__inside_watch} = 1;
  } elsif ($uc_command eq 'UNWATCH') {
      delete $self->{__inside_watch};
  }

  ## Fast path, no reconnect;
  $self->{reconnect}
    or return $self->__run_cmd($command, $collect_errors, undef, $cb, @_);

  my @cmd_args = @_;
  $self->__with_reconnect(
    sub {
      $self->__run_cmd($command, $collect_errors, undef, $cb, @cmd_args);
    }
  );
}

sub __with_reconnect {
  my ($self, $cb) = @_;

  ## Fast path, no reconnect
  $self->{reconnect}
    or return $cb->();

  return &try(
    $cb,
    catch {
      ref($_) eq 'Redis::X::Reconnect'
        or die $_;

      $self->{__inside_transaction} || $self->{__inside_watch}
        and croak("reconnect disabled inside transaction or watch");

      scalar @{$self->{queue} || []} && $self->{conservative_reconnect}
        and croak("reconnect disabled while responses are pending and conservative reconnect mode enabled");

      $self->connect;
      $cb->();
    }
  );
}

sub __run_cmd {
  my ($self, $command, $collect_errors, $custom_decode, $cb, @args) = @_;

  my $ret;
  my $wrapper = $cb && $custom_decode
    ? sub {
      my ($reply, $error) = @_;
      $cb->(scalar $custom_decode->($reply), $error);
    }
    : $cb || sub {
      my ($reply, $error) = @_;
      croak "[$command] $error, " if defined $error;
      $ret = $reply;
    };

  $self->__send_command($command, @args);
  push @{ $self->{queue} }, [$command, $wrapper, $collect_errors];

  return 1 if $cb;

  $self->wait_all_responses;
  return
      $custom_decode ? $custom_decode->($ret, !wantarray)
    : wantarray && ref $ret eq 'ARRAY' ? @$ret
    :                                    $ret;
}

sub wait_all_responses {
  my ($self) = @_;

  my $queue = $self->{queue};
  $self->wait_one_response while @$queue;

  return;
}

sub wait_one_response {
  my ($self) = @_;

  my $handler = shift @{ $self->{queue} };
  return unless $handler;

  my ($command, $cb, $collect_errors) = @$handler;
  $cb->($self->__read_response($command, $collect_errors));

  return;
}


### Commands with extra logic
sub quit {
  my ($self) = @_;
  return unless $self->{sock};

  croak "[quit] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  try {
    $self->wait_all_responses;
    $self->__send_command('QUIT');
  };

  $self->__close_sock();

  return 1;
}

sub shutdown {
  my ($self) = @_;
  $self->__is_valid_command('SHUTDOWN');

  croak "[shutdown] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  return unless $self->{sock};

  $self->wait_all_responses;
  $self->__send_command('SHUTDOWN');
  $self->__close_sock() || croak("Can't close socket: $!");

  return 1;
}

sub ping {
  my $self = shift;
  $self->__is_valid_command('PING');

  croak "[ping] only works in synchronous mode, "
    if @_ && ref $_[-1] eq 'CODE';

  return unless defined $self->{sock};

  $self->wait_all_responses;
  return scalar try {
    $self->__std_cmd('PING');
  }
  catch {
    $self->__close_sock();
    return;
  };
}

sub info {
  my $self = shift;
  $self->__is_valid_command('INFO');

  my $custom_decode = sub {
    my ($reply) = @_;
    return $reply if !defined $reply || ref $reply;
    return { map { split(/:/, $_, 2) } grep {/^[^#]/} split(/\r\n/, $reply) };
  };

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  ## Fast path, no reconnect
  return $self->__run_cmd('INFO', 0, $custom_decode, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(
    sub {
      $self->__run_cmd('INFO', 0, $custom_decode, $cb, @cmd_args);
    }
  );
}

sub keys {
  my $self = shift;
  $self->__is_valid_command('KEYS');

  my $custom_decode = sub {
    my ($reply, $synchronous_scalar) = @_;

    ## Support redis <= 1.2.6
    $reply = [split(/\s/, $reply)] if defined $reply && !ref $reply;

    return ref $reply && ($synchronous_scalar || wantarray) ? @$reply : $reply;
  };

  my $cb = @_ && ref $_[-1] eq 'CODE' ? pop : undef;

  ## Fast path, no reconnect
  return $self->__run_cmd('KEYS', 0, $custom_decode, $cb, @_)
    unless $self->{reconnect};

  my @cmd_args = @_;
  $self->__with_reconnect(
    sub {
      $self->__run_cmd('KEYS', 0, $custom_decode, $cb, @cmd_args);
    }
  );
}

sub scan_callback {
  my $self = shift;
  my $cb = pop;
  my $pattern = shift || '*';

  my $cursor = 0;
  do {
    ($cursor, my $list) = $self->scan( $cursor, MATCH => $pattern );
    local $_;
    for (@$list) {
      $cb->($self, $_);
    };
  } while $cursor;

  return $self; 
}

### PubSub
sub wait_for_messages {
  my ($self, $timeout) = @_;

  my $s = IO::Select->new;

  my $count = 0;


  my $e;

  try {
    $self->__with_reconnect( sub {

      # the socket can be changed due to reconnection, so get it each time
      my $sock = $self->{sock};
      $s->remove($s->handles);
      $s->add($sock);

      while ($s->can_read($timeout)) {
        my $has_stuff = $self->__try_read_sock($sock);
        # If the socket is ready to read but there is nothing to read, ( so
        # it's an EOF ), try to reconnect.
        defined $has_stuff
          or $self->__throw_reconnect('EOF from server');

        my $cond;

        if ( ! $self->{ssl} ) {
          $cond = sub {
            # if __try_read_sock() return 0 (no data)
            # or undef ( socket became EOF), back to select until timeout
            return $self->{__buf} || $self->__try_read_sock($sock);
          }
        } else {
          $cond = sub {
            # continue if there is still some data left.  If the buffer is
            # larger than 16K, there won't be any pending data left though
            return $self->{__buf} || $sock->pending;
          }
        }

        do {
          my ($reply, $error) = $self->__read_response('WAIT_FOR_MESSAGES');
          croak "[WAIT_FOR_MESSAGES] $error, " if defined $error;
          $self->__process_pubsub_msg($reply);
          $count++;

        } while ($cond->());
      }

    });

  } catch {
    $e = $_;
};

# if We had an error and it was not an EOF, die
defined $e && $e ne 'EOF from server'
  and die $e;

  return $count;
}

sub __subscription_cmd {
  my $self    = shift;
  my $pr      = shift;
  my $unsub   = shift;
  my $command = shift;
  my $cb      = pop;

  croak("Missing required callback in call to $command(), ")
    unless ref($cb) eq 'CODE';

  $self->wait_all_responses;

  my @subs = @_;
  $self->__with_reconnect(
    sub {
      $self->__throw_reconnect('Not connected to any server')
        unless $self->{sock};

      @subs = $self->__process_unsubscribe_requests($cb, $pr, @subs)
        if $unsub;
      return unless @subs;

      $self->__send_command($command, @subs);

      my %cbs = map { ("${pr}message:$_" => $cb) } @subs;
      return $self->__process_subscription_changes($command, \%cbs);
    }
  );
}

sub subscribe    { shift->__subscription_cmd('',  0, subscribe    => @_) }
sub psubscribe   { shift->__subscription_cmd('p', 0, psubscribe   => @_) }
sub unsubscribe  { shift->__subscription_cmd('',  1, unsubscribe  => @_) }
sub punsubscribe { shift->__subscription_cmd('p', 1, punsubscribe => @_) }

sub __process_unsubscribe_requests {
  my ($self, $cb, $pr, @unsubs) = @_;
  my $subs = $self->{subscribers};

  my @subs_to_unsubscribe;
  for my $sub (@unsubs) {
    my $key = "${pr}message:$sub";
    my $cbs = $subs->{$key} = [grep { $_ ne $cb } @{ $subs->{$key} }];
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
    my ($m, $error) = $self->__read_response($cmd);
    croak "[$cmd] $error, " if defined $error;

    ## Deal with pending PUBLISH'ed messages
    if ($m->[0] =~ /^p?message$/) {
      $self->__process_pubsub_msg($m);
      next;
    }

    my ($key, $unsub) = $m->[0] =~ m/^(p)?(un)?subscribe$/;
    $key .= "message:$m->[1]";
    my $cb = delete $expected->{$key};

    push @{ $subs->{$key} }, $cb unless $unsub;

    $self->{is_subscriber} = $m->[2];
  }
}

sub __process_pubsub_msg {
  my ($self, $m) = @_;
  my $subs = $self->{subscribers};

  my $sub   = $m->[1];
  my $cbid  = "$m->[0]:$sub";
  my $data  = pop @$m;
  my $topic = defined $m->[2] ? $m->[2] : $sub;

  if (!defined $subs->{$cbid}) {
    warn "Message for topic '$topic' ($cbid) without expected callback, ";
    return;
  }

  $_->($data, $topic, $sub) for @{ $subs->{$cbid} };

  return 1;

}


### Mode validation
sub __is_valid_command {
  my ($self, $cmd) = @_;

  croak("Cannot use command '$cmd' while in SUBSCRIBE mode, ")
    if $self->{is_subscriber};
}


### Socket operations
sub connect {
  my ($self) = @_;
  delete $self->{sock};
  delete $self->{__inside_watch};
  delete $self->{__inside_transaction};

  # Suppose we have at least one command response pending, but we're about
  # to reconnect.  The new connection will never get a response to any of
  # the pending commands, so delete all those pending responses now.
  $self->{queue} = [];
  $self->{pid}   = $$;

  ## Fast path, no reconnect
  return $self->__build_sock() unless $self->{reconnect};

  ## Use precise timers on reconnections
  require Time::HiRes;
  my $t0 = [Time::HiRes::gettimeofday()];

  ## Reconnect...
  while (1) {
    eval { $self->__build_sock };

    last unless $@;    ## Connected!
    die if Time::HiRes::tv_interval($t0) > $self->{reconnect};    ## Timeout
    Time::HiRes::usleep($self->{every});                          ## Retry in...
  }

  return;
}

sub __build_sock {
  my ($self) = @_;

  do {
    $self->{sock} = $self->{builder}->($self);
  } while (!$self->{sock} && $! == Errno::EINTR);

  unless ($self->{sock}) {
    croak("Could not connect to Redis server at $self->{server}: $!");
  }

  $self->{__buf} = '';

  if (defined $self->{username} && defined $self->{password}) {
    try { $self->auth($self->{username}, $self->{password}) }
    catch {
      my $error = $_;
      $self->{reconnect} = 0;
      croak('Redis server authentication error: ' . $error);
    };
  } elsif (defined $self->{password}) {
    try { $self->auth($self->{password}) }
    catch {
      my $error = $_;
      $self->{reconnect} = 0;
      croak('Redis server authentication error: ' . $error);
    };
  }

  $self->__on_connection;

  return;
}

sub __close_sock {
  my ($self) = @_;
  $self->{__buf} = '';
  delete $self->{__inside_watch};
  delete $self->{__inside_transaction};
  defined $self->{sock} or return 1;
  return close(delete $self->{sock});
}

sub __on_connection {

    my ($self) = @_;

    # If we are in PubSub mode we shouldn't perform any command besides
    # (p)(un)subscribe
    if (! $self->{is_subscriber}) {
      defined $self->{name}
        and try {
            my $n = $self->{name};
            $n = $n->($self) if ref($n) eq 'CODE';
            $self->client_setname($n) if defined $n;
        };

      # don't use select() function as it's caching database name,
      # rather call select directly
      defined $self->{current_database}
        and $self->__std_cmd('select', $self->{current_database});
    }

    foreach my $topic (CORE::keys(%{$self->{subscribers}})) {
      if ($topic =~ /(p?message):(.*)$/ ) {
        my ($key, $channel) = ($1, $2);
        if ($key eq 'message') {
            $self->__send_command('subscribe', $channel);
            my (undef, $error) = $self->__read_response('subscribe');
            defined $error
              and croak "[subscribe] $error";
        } else {
            $self->__send_command('psubscribe', $channel);
            my (undef, $error) = $self->__read_response('psubscribe');
            defined $error
              and croak "[psubscribe] $error";
        }
      }
    }

    defined $self->{on_connect}
      and $self->{on_connect}->($self);

}


sub __send_command {
  my $self = shift;
  my $cmd  = uc(shift);
  my $deb  = $self->{debug};

  # if already connected but after a fork, reconnect
  if ($self->{sock} && ($self->{pid} || 0) != $$) {
    $self->connect;
  }

  my $sock = $self->{sock}
    || $self->__throw_reconnect('Not connected to any server');

  warn "[SEND] $cmd ", Dumper([@_]) if $deb;

  ## Encode command using multi-bulk format
  my @cmd     = split /_/, $cmd;
  my $n_elems = scalar(@_) + scalar(@cmd);
  my $buf     = "\*$n_elems\r\n";
  for my $bin (@cmd, @_) {
    utf8::downgrade($bin, 1)
      or croak "command sent is not an octet sequence in the native encoding (Latin-1). Consider using debug mode to see the command itself.";
    $buf .= defined($bin) ? '$' . length($bin) . "\r\n$bin\r\n" : "\$-1\r\n";
  }

  # this function works differently with a SSL socket cause it's not
  # possible to read just a few bytes from a TLS frame.
  my $status = $self->__try_read_sock($sock);
  $self->__throw_reconnect('Not connected to any server')
    unless defined $status;

  ## Send command, take care for partial writes
  warn "[SEND RAW] $buf" if $deb;
  while ($buf) {
    my $len = syswrite $sock, $buf, length $buf;
    $self->__throw_reconnect("Could not write to Redis server: $!")
      unless defined $len;
    substr $buf, 0, $len, "";
  }

  return;
}

sub __read_response {
  my ($self, $cmd, $collect_errors) = @_;

  croak("Not connected to any server") unless $self->{sock};

  local $/ = "\r\n";

  ## no debug => fast path
  return $self->__read_response_r($cmd, $collect_errors) unless $self->{debug};

  my ($result, $error) = $self->__read_response_r($cmd, $collect_errors);
  warn "[RECV] $cmd ", Dumper($result, $error);
  return $result, $error;
}

sub __read_response_r {
  my ($self, $command, $collect_errors) = @_;

  my ($type, $result) = $self->__read_line;

  if ($type eq '-') {
    return undef, $result;
  }
  elsif ($type eq '+' || $type eq ':') {
    return $result, undef;
  }
  elsif ($type eq '$') {
    return undef, undef if $result < 0;
    return $self->__read_len($result + 2), undef;
  }
  elsif ($type eq '*') {
    return undef, undef if $result < 0;

    my @list;
    while ($result--) {
      my @nested = $self->__read_response_r($command, $collect_errors);
      if ($collect_errors) {
        push @list, \@nested;
      }
      else {
        croak "[$command] $nested[1], " if defined $nested[1];
        push @list, $nested[0];
      }
    }
    return \@list, undef;
  }
  else {
    croak "unknown answer type: $type ($result), ";
  }
}

sub __read_line {
  my $self = $_[0];
  my $sock = $self->{sock};

  my $data = $self->__read_line_raw;
  if (! defined $data) {
      # In case the caller catches the exception and wants to persist on using
      # the redis connection, let's forbid that.
      $self->__close_sock();
      croak("Error while reading from Redis server: $!")
  }

  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  my $type = substr($data, 0, 1, '');
  return ($type, $data);
}

sub __read_line_raw {
  my $self = $_[0];
  my $sock = $self->{sock};
  my $buf = \$self->{__buf};

  if (length $$buf) {
    my $idx = index($$buf, "\r\n");
    $idx >= 0 and return substr($$buf, 0, $idx + 2, '');
  }

  while (1) {
    my $bytes = sysread($sock, $$buf, BUFSIZE, length($$buf));
    next if !defined $bytes && $! == EINTR;
    return unless defined $bytes && $bytes;

    # start looking for \r\n where we stopped last time
    # extracting one is required to handle corner case
    # where \r\n are split and therefore read by two conseqent sysreads
    my $idx = index($$buf, "\r\n", length($$buf) - $bytes - 1);
    $idx >= 0 and return substr($$buf, 0, $idx + 2, '');
  }
}

sub __read_len {
  my ($self, $len) = @_;
  my $buf = \$self->{__buf};
  my $buflen = length($$buf);

  if ($buflen < $len) {
    my $to_read = $len - $buflen;
    while ($to_read > 0) {
      my $bytes = sysread($self->{sock}, $$buf, BUFSIZE, length($$buf));
      next if !defined $bytes && $! == EINTR;
      croak("Error while reading from Redis server: $!") unless defined $bytes;
      croak("Redis server closed connection") unless $bytes;
      $to_read -= $bytes;
    }
  }

  my $data = substr($$buf, 0, $len, '');
  chomp $data;
  warn "[RECV RAW] '$data'" if $self->{debug};

  return $data;
}

sub __try_read_sock {
  my ($self, $sock) = @_;
  my $data = '';

  while (1) {
      # WIN32 doesn't support MSG_DONTWAIT,
      # need to swith fh to nonblockng mode manually.
      # For Unix still use MSG_DONTWAIT because of fewer syscalls
      my ($res, $err);
      if (WIN32) {
          __fh_nonblocking_win32($sock, 1);
          $res = recv($sock, $data, BUFSIZE, 0);
          $err = 0 + $!;
          __fh_nonblocking_win32($sock, 0);
      } else {
          if ($self->{ssl}) {
              ## use peek to see if there is any data available instead of reading
              ## it cause it's not possible to read only a few bytes from an SSL
              ## frame.  This does not work in WIN32
              $sock->blocking(0);
              $res = $sock->peek($data, BUFSIZE);
              $sock->blocking(1);
          } else {
              $res = recv($sock, $data, BUFSIZE, MSG_DONTWAIT);
          }

          $err = 0 + $!;
      }

      if (defined $res) {
        ## have read some data
        if (length($data)) {
            $self->{__buf} .= $data unless $self->{ssl};
            return 1;
        }

        ## no data but also no error means EOF
        return;
      }

      next if $err && $err == EINTR;

      ## Keep going if nothing there, but socket is alive
      return 0 if $err and ($err == EWOULDBLOCK or $err == EAGAIN);

      ## if we got ECONNRESET, it might be due a timeout from the other side (on freebsd)
      ## or because an intermediate proxy shut down our connection using its internal timeout counter
      return 0 if ($err && $err == ECONNRESET);

      ## result is undef but err is 0? should never happen
      return if $err == 0;

      ## For everything else, there is Mastercard...
      croak("Unexpected error condition $err/$^O, please report this as a bug");
  }
}

## Copied from AnyEvent::Util
sub __fh_nonblocking_win32 {
    ioctl $_[0], 0x8004667e, pack "L", $_[1];
}

##########################
# I take exception to that

sub __throw_reconnect {
  my ($self, $m) = @_;
  die bless(\$m, 'Redis::X::Reconnect') if $self->{reconnect};
  die $m;
}


1;    # End of Redis.pm

__END__

=head1 SYNOPSIS

    ## Defaults to $ENV{REDIS_SERVER} or 127.0.0.1:6379
    my $redis = Redis->new;

    my $redis = Redis->new(server => 'redis.example.com:8080');

    ## Set the connection name (requires Redis 2.6.9)
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => 'my_connection_name',
    );
    my $generation = 0;
    my $redis = Redis->new(
      server => 'redis.example.com:8080',
      name => sub { "cache-$$-".++$generation },
    );

    ## Use UNIX domain socket
    my $redis = Redis->new(sock => '/path/to/socket');

    ## Connect to Redis over a secure SSL/TLS channel.  See
    ## IO::Socket::SSL documentation for more information
    ## about SSL_verify_mode parameter.
    my $redis = Redis->new(
        server => 'redis.tls.example.com:8080',
        ssl => 1,
        SSL_verify_mode => SSL_VERIFY_PEER,
    );

    ## Enable auto-reconnect
    ## Try to reconnect every 1s up to 60 seconds until success
    ## Die if you can't after that
    my $redis = Redis->new(reconnect => 60, every => 1_000_000);

    ## Try each 100ms up to 2 seconds (every is in microseconds)
    my $redis = Redis->new(reconnect => 2, every => 100_000);

    ## Enable connection timeout (in seconds)
    my $redis = Redis->new(cnx_timeout => 60);

    ## Enable read timeout (in seconds)
    my $redis = Redis->new(read_timeout => 0.5);

    ## Enable write timeout (in seconds)
    my $redis = Redis->new(write_timeout => 1.2);

    ## Connect via a list of Sentinels to a given service
    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345' ], service => 'mymaster');

    ## Same, but with connection, read and write timeout on the sentinel hosts
    my $redis = Redis->new( sentinels => [ '127.0.0.1:12345' ], service => 'mymaster',
                            sentinels_cnx_timeout => 0.1,
                            sentinels_read_timeout => 1,
                            sentinels_write_timeout => 1,
                          );

    ## Use all the regular Redis commands, they all accept a list of
    ## arguments
    ## See https://redis.io/commands for full list
    $redis->get('key');
    $redis->set('key' => 'value');
    $redis->sort('list', 'DESC');
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC});

    ## Add a coderef argument to run a command in the background
    $redis->sort(qw{list LIMIT 0 5 ALPHA DESC}, sub {
      my ($reply, $error) = @_;
      die "Oops, got an error: $error\n" if defined $error;
      print "$_\n" for @$reply;
    });
    long_computation();
    $redis->wait_all_responses;
    ## or
    $redis->wait_one_response();

    ## Or run a large batch of commands in a pipeline
    my %hash = _get_large_batch_of_commands();
    $redis->hset('h', $_, $hash{$_}, sub {}) for keys %hash;
    $redis->wait_all_responses;

    ## Publish/Subscribe
    $redis->subscribe(
      'topic_1',
      'topic_2',
      sub {
        my ($message, $topic, $subscribed_topic) = @_

          ## $subscribed_topic can be different from topic if
          ## you use psubscribe() with wildcards
      }
    );
    $redis->psubscribe('nasdaq.*', sub {...});

    ## Blocks and waits for messages, calls subscribe() callbacks
    ##  ... forever
    my $timeout = 10;
    $redis->wait_for_messages($timeout) while 1;

    ##  ... until some condition
    my $keep_going = 1; ## other code will set to false to quit
    $redis->wait_for_messages($timeout) while $keep_going;

    $redis->publish('topic_1', 'message');


=head1 DESCRIPTION

Pure perl bindings for L<https://redis.io/>

This version supports protocol 2.x (multi-bulk) or later of Redis available at
L<https://github.com/antirez/redis/>.

This documentation lists commands which are exercised in test suite, but
additional commands will work correctly since protocol specifies enough
information to support almost all commands with same piece of code with a
little help of C<AUTOLOAD>.


=head1 PIPELINING

Usually, running a command will wait for a response.  However, if you're doing
large numbers of requests, it can be more efficient to use what Redis calls
I<pipelining>: send multiple commands to Redis without waiting for a response,
then wait for the responses that come in.

To use pipelining, add a coderef argument as the last argument to a command
method call:

  $r->set('foo', 'bar', sub {});

Pending responses to pipelined commands are processed in a single batch, as
soon as at least one of the following conditions holds:

=over

=item *

A non-pipelined (synchronous) command is called on the same connection

=item *

A pub/sub subscription command (one of C<subscribe>, C<unsubscribe>,
C<psubscribe>, or C<punsubscribe>) is about to be called on the same
connection.

=item *

One of L</wait_all_responses> or L</wait_one_response> methods is called
explicitly.

=back

The coderef you supply to a pipelined command method is invoked once the
response is available.  It takes two arguments, C<$reply> and C<$error>.  If
C<$error> is defined, it contains the text of an error reply sent by the Redis
server.  Otherwise, C<$reply> is the non-error reply. For almost all commands,
that means it's C<undef>, or a defined but non-reference scalar, or an array
ref of any of those; but see L</keys>, L</info>, and L</exec>.

Note the contrast with synchronous commands, which throw an exception on
receipt of an error reply, or return a non-error reply directly.

The fact that pipelined commands never throw an exception can be particularly
useful for Redis transactions; see L</exec>.


=head1 ENCODING

There is no encoding feature anymore, it has been deprecated and finally
removed. This module consider that any data sent to the Redis server is a binary data.
And it doesn't do anything when getting data from the Redis server.

So, if you are working with character strings, you should pre-encode or post-decode it if needed !

=head1 CONSTRUCTOR

=head2 new

    my $r = Redis->new; # $ENV{REDIS_SERVER} or 127.0.0.1:6379

    my $r = Redis->new( server => '192.168.0.1:6379', debug => 0 );
    my $r = Redis->new( server => '192.168.0.1:6379', encoding => undef );
    my $r = Redis->new( server => '192.168.0.1:6379', ssl => 1, SSL_verify_mode => SSL_VERIFY_PEER );
    my $r = Redis->new( sock => '/path/to/sock' );
    my $r = Redis->new( reconnect => 60, every => 5000 );
    my $r = Redis->new( password => 'boo' );
    my $r = Redis->new( on_connect => sub { my ($redis) = @_; ... } );
    my $r = Redis->new( name => 'my_connection_name' );
    my $r = Redis->new( name => sub { "cache-for-$$" });

    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345', '127.0.0.1:23456' ],
                           service => 'mymaster');

    ## Connect via a list of Sentinels to a given service
    my $redis = Redis->new(sentinels => [ '127.0.0.1:12345' ], service => 'mymaster');

    ## Same, but with connection, read and write timeout on the sentinel hosts
    my $redis = Redis->new( sentinels => [ '127.0.0.1:12345' ], service => 'mymaster',
                            sentinels_cnx_timeout => 0.1,
                            sentinels_read_timeout => 1,
                            sentinels_write_timeout => 1,
                          );

=head3 C<< server >>

The C<< server >> parameter specifies the Redis server we should connect to,
via TCP. Use the 'IP:PORT' format. If no C<< server >> option is present, we
will attempt to use the C<< REDIS_SERVER >> environment variable. If neither of
those options are present, it defaults to '127.0.0.1:6379'.

Alternatively you can use the C<< sock >> parameter to specify the path of the
UNIX domain socket where the Redis server is listening.

Alternatively you can use the C<< sentinels >> parameter and the C<< service >>
parameter to specify a list of sentinels to contact and try to get the address
of the given service name. C<< sentinels >> must be an ArrayRef and C<< service
>> an Str.

The C<< REDIS_SERVER >> can be used for UNIX domain sockets too. The following
formats are supported:

=over

=item *

/path/to/sock

=item *

unix:/path/to/sock

=item *

127.0.0.1:11011

=item *

tcp:127.0.0.1:11011

=back

=head3 C<< reconnect >>, C<< every >>

The C<< reconnect >> option enables auto-reconnection mode. If we cannot
connect to the Redis server, or if a network write fails, we enter retry mode.
We will try a new connection every C<< every >> microseconds (1 ms by
default), up-to C<< reconnect >> seconds.

Be aware that read errors will always thrown an exception, and will not trigger
a retry until the new command is sent.

If we cannot re-establish a connection after C<< reconnect >> seconds, an
exception will be thrown.

=head3 C<< conservative_reconnect >>

C<< conservative_reconnect >> option makes sure that reconnection is only attempted
when no pending command is ongoing. For instance, if you're doing
C<<$redis->incr('key')>>, and if the server properly understood and processed the
command, but the network connection is dropped just before the server replies :
the command has been processed but the client doesn't know it. In this
situation, if reconnect is enabled, the Redis client will reconnect and send
the C<incr> command *again*. If it succeeds, at the end the key as been
incremented *two* times. To avoid this issue, you can set the C<conservative_reconnect>
option to a true value. In this case, the client will reconnect only if no
request is pending. Otherwise it will die with the message: C<reconnect
disabled while responses are pending and safe reconnect mode enabled>.

=head3 C<< cnx_timeout >>

The C<< cnx_timeout >> option enables connection timeout. The Redis client will
wait at most that number of seconds (can be fractional) before giving up
connecting to a server.

=head3 C<< sentinels_cnx_timeout >>

The C<< sentinels_cnx_timeout >> option enables sentinel connection timeout.
When using the sentinels feature, Redis client will wait at most that number of
seconds (can be fractional) before giving up connecting to a sentinel.
B<Default>: 0.1

=head3 C<< read_timeout >>

The C<< read_timeout >> option enables read timeout. The Redis client will wait
at most that number of seconds (can be fractional) before giving up when
reading from the server.

=head3 C<< sentinels_read_timeout >>

The C<< sentinels_read_timeout >> option enables sentinel read timeout. When
using the sentinels feature, the Redis client will wait at most that number of
seconds (can be fractional) before giving up when reading from a sentinel
server. B<Default>: 1

=head3 C<< write_timeout >>

The C<< write_timeout >> option enables write timeout. The Redis client will wait
at most that number of seconds (can be fractional) before giving up when
reading from the server.

=head3 C<< sentinels_write_timeout >>

The C<< sentinels_write_timeout >> option enables sentinel write timeout. When
using the sentinels feature, the Redis client will wait at most that number of
seconds (can be fractional) before giving up when reading from a sentinel
server. B<Default>: 1

=head3 C<< password >>

If your Redis server requires authentication, you can use the C<< password >>
attribute. After each established connection (at the start or when
reconnecting), the Redis C<< AUTH >> command will be send to the server. If the
password is wrong, an exception will be thrown and reconnect will be disabled.

=head3 C<< on_connect >>

You can also provide a code reference that will be immediately after each
successful connection. The C<< on_connect >> attribute is used to provide the
code reference, and it will be called with the first parameter being the Redis
object.

=head3 C<< no_auto_connect_on_new >>

You can also provide C<< no_auto_connect_on_new >> in which case C<<
new >> won't call C<< $obj->connect >> for you implicitly, you'll have
to do that yourself. This is useful for figuring out how long
connection setup takes so you can configure the C<< cnx_timeout >>
appropriately.

=head3 C<< no_sentinels_list_update >>

You can also provide C<< no_sentinels_list_update >>. By default (that is,
without this option), when successfully contacting a sentinel server, the Redis
client will ask it for the list of sentinels known for the given service, and
merge it with its list of sentinels (in the C<< sentinels >> attribute). You
can disable this behavior by setting C<< no_sentinels_list_update >> to a true
value.

=head3 C<< name >>

You can also set a name for each connection. This can be very useful for
debugging purposes, using the C<< CLIENT LIST >> command. To set a connection
name, use the C<< name >> parameter. You can use both a scalar value or a
CodeRef. If the latter, it will be called after each connection, with the Redis
object, and it should return the connection name to use. If it returns a
undefined value, Redis will not set the connection name.

Please note that there are restrictions on the name you can set, the most
important of which is, no spaces. See the L<CLIENT SETNAME
documentation|https://redis.io/commands/client-setname> for all the juicy
details. This feature is safe to use with all versions of Redis servers. If C<<
CLIENT SETNAME >> support is not available (Redis servers 2.6.9 and above
only), the name parameter is ignored.

=head3 C<< ssl >>

You can connect to Redis over SSL/TLS by setting this flag if the target Redis
server or cluster has been setup to support SSL/TLS.  This requires IO::Socket::SSL
to be installed on the client.  It's off by default.

=head3 C<< SSL_verify_mode >>

This parameter will be applied when C<< ssl >> flag is set.  It sets the verification
mode for the peer certificate.  It's compatible with the parameter with the same name
in IO::Socket::SSL.

=head3 C<< debug >>

The C<< debug >> parameter enables debug information to STDERR, including all
interactions with the server. You can also enable debug with the C<REDIS_DEBUG>
environment variable.

=head1 CONNECTION HANDLING

=head2 connect

  $r->connect;

Connects to the Redis server. This is done by default when the obect is
constructed using C<new()>, unless C<no_auto_connect_on_new> has been set. See
this option in the C<new()> constructor.

=head2 quit

  $r->quit;

Closes the connection to the server. The C<quit> method does not support
pipelined operation.

=head2 ping

  $r->ping || die "no server?";

The C<ping> method does not support pipelined operation.

=head1 PIPELINE MANAGEMENT

=head2 wait_all_responses

Waits until all pending pipelined responses have been received, and invokes the
pipeline callback for each one.  See L</PIPELINING>.

=head2 wait_one_response

Waits until the first pending pipelined response has been received, and invokes
its callback.  See L</PIPELINING>.

=head1 PUBLISH/SUBSCRIBE COMMANDS

When one of L</subscribe> or L</psubscribe> is used, the Redis object will
enter I<PubSub> mode. When in I<PubSub> mode only commands in this section,
plus L</quit>, will be accepted.

If you plan on using PubSub and other Redis functions, you should use two Redis
objects, one dedicated to PubSub and the other for regular commands.

All Pub/Sub commands receive a callback as the last parameter. This callback
receives three arguments:

=over

=item *

The published message.

=item *

The topic over which the message was sent.

=item *

The subscribed topic that matched the topic for the message. With L</subscribe>
these last two are the same, always. But with L</psubscribe>, this parameter
tells you the pattern that matched.

=back

See the L<Pub-Sub notes|https://redis.io/topics/pubsub> for more information
about the messages you will receive on your callbacks after each L</subscribe>,
L</unsubscribe>, L</psubscribe> and L</punsubscribe>.

=head2 publish

  $r->publish($topic, $message);

Publishes the C<< $message >> to the C<< $topic >>.

=head2 subscribe

  $r->subscribe(
      @topics_to_subscribe_to,
      my $savecallback = sub {
        my ($message, $topic, $subscribed_topic) = @_;
        ...
      },
  );

Subscribe one or more topics. Messages published into one of them will be
received by Redis, and the specified callback will be executed.

=head2 unsubscribe

  $r->unsubscribe(@topic_list, $savecallback);

Stops receiving messages via C<$savecallback> for all the topics in
C<@topic_list>. B<WARNING:> it is important that you give the same calleback
that you used for subscribtion. The value of the CodeRef must be the same, as
this is how internally the code identifies it.

=head2 psubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->psubscribe(@topic_matches, my $savecallback = sub { my ($m, $t, $s) = @_; ... });

Subscribes a pattern of topics. All messages to topics that match the pattern
will be delivered to the callback.

=head2 punsubscribe

  my @topic_matches = ('prefix1.*', 'prefix2.*');
  $r->punsubscribe(@topic_matches, $savecallback);

Stops receiving messages via C<$savecallback> for all the topics pattern
matches in C<@topic_list>. B<WARNING:> it is important that you give the same
calleback that you used for subscribtion. The value of the CodeRef must be the
same, as this is how internally the code identifies it.

=head2 is_subscriber

  if ($r->is_subscriber) { say "We are in Pub/Sub mode!" }

Returns true if we are in I<Pub/Sub> mode.

=head2 wait_for_messages

  my $keep_going = 1; ## Set to false somewhere to leave the loop
  my $timeout = 5;
  $r->wait_for_messages($timeout) while $keep_going;

Blocks, waits for incoming messages and delivers them to the appropriate
callbacks.

Requires a single parameter, the number of seconds to wait for messages. Use 0
to wait for ever. If a positive non-zero value is used, it will return after
that amount of seconds without a single notification.

Please note that the timeout is not a commitment to return control to the
caller at most each C<timeout> seconds, but more a idle timeout, were control
will return to the caller if Redis is idle (as in no messages were received
during the timeout period) for more than C<timeout> seconds.

The L</wait_for_messages> call returns the number of messages processed during
the run.

=head1 IMPORTANT NOTES ON METHODS

=head2 methods that return multiple values

When a method returns more than one value, it checks the context and returns
either a list of values or an ArrayRef.

=head2 transaction-handling methods

B<Warning:> the behaviour of the TRANSACTIONS commands when combined with
pipelining is still under discussion, and you should B<NOT> use them at the
same time just now.

You can L<follow the discussion to see the open issues with
this|https://github.com/PerlRedis/perl-redis/issues/17>.

=head2 exec

  my @individual_replies = $r->exec;

C<exec> has special behaviour when run in a pipeline: the C<$reply> argument to
the pipeline callback is an array ref whose elements are themselves C<[$reply,
$error]> pairs.  This means that you can accurately detect errors yielded by
any command in the transaction, and without any exceptions being thrown.

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );
  my $keys = $r->keys( '*glob_pattern*' ); # count of matching keys

Note that synchronous C<keys> calls in a scalar context return the number of
matching keys (not an array ref of matching keys as you might expect).  This
does not apply in pipelined mode: assuming the server returns a list of keys,
as expected, it is always passed to the pipeline callback as an array ref.

=head2 hashes

Hashes in Redis cannot be nested as in perl, if you want to store a nested
hash, you need to serialize the hash first. If you want to have a named
hash, you can use Redis-hashes. You will find an example in the tests
of this module t/01-basic.t

=head2 eval

Note that this commands sends the Lua script every time you call it. See
L</evalsha> and L</script_load> for an alternative.

=head2 info

  my $info_hash = $r->info;

The C<info> method is unique in that it decodes the server's response into a
hashref, if possible. This decoding happens in both synchronous and pipelined
modes.

=head1 KEYS

=head2 del

  $r->del(key [key ...])

Delete a key (see L<https://redis.io/commands/del>)

=head2 dump

  $r->dump(key)

Return a serialized version of the value stored at the specified key. (see L<https://redis.io/commands/dump>)

=head2 exists

  $r->exists(key)

Determine if a key exists (see L<https://redis.io/commands/exists>)

=head2 expire

  $r->expire(key, seconds)

Set a key's time to live in seconds (see L<https://redis.io/commands/expire>)

=head2 expireat

  $r->expireat(key, timestamp)

Set the expiration for a key as a UNIX timestamp (see L<https://redis.io/commands/expireat>)

=head2 keys

  $r->keys(pattern)

Find all keys matching the given pattern (see L<https://redis.io/commands/keys>)

=head2 migrate

  $r->migrate(host, port, key, destination-db, timeout, [COPY], [REPLACE])

Atomically transfer a key from a Redis instance to another one. (see L<https://redis.io/commands/migrate>)

=head2 move

  $r->move(key, db)

Move a key to another database (see L<https://redis.io/commands/move>)

=head2 object

  $r->object(subcommand, [arguments [arguments ...]])

Inspect the internals of Redis objects (see L<https://redis.io/commands/object>)

=head2 persist

  $r->persist(key)

Remove the expiration from a key (see L<https://redis.io/commands/persist>)

=head2 pexpire

  $r->pexpire(key, milliseconds)

Set a key's time to live in milliseconds (see L<https://redis.io/commands/pexpire>)

=head2 pexpireat

  $r->pexpireat(key, milliseconds-timestamp)

Set the expiration for a key as a UNIX timestamp specified in milliseconds (see L<https://redis.io/commands/pexpireat>)

=head2 pttl

  $r->pttl(key)

Get the time to live for a key in milliseconds (see L<https://redis.io/commands/pttl>)

=head2 randomkey

  $r->randomkey()

Return a random key from the keyspace (see L<https://redis.io/commands/randomkey>)

=head2 rename

  $r->rename(key, newkey)

Rename a key (see L<https://redis.io/commands/rename>)

=head2 renamenx

  $r->renamenx(key, newkey)

Rename a key, only if the new key does not exist (see L<https://redis.io/commands/renamenx>)

=head2 restore

  $r->restore(key, ttl, serialized-value)

Create a key using the provided serialized value, previously obtained using DUMP. (see L<https://redis.io/commands/restore>)

=head2 scan

  $r->scan(cursor, [MATCH pattern], [COUNT count])

Incrementally iterate the keys space (see L<https://redis.io/commands/scan>)

=head3 Note on cursor.

 As documented as above, in perl this looks as follows:

  my $cursor = 0;  my $result = [];
  do { ($cursor, $result) = $r->scan($cursor, 'MATCH', '*'); ... }
      while ( $cursor );

=head2 scan_callback

  $r->scan_callback( sub { print "$_\n" } );

  $r->scan_callback( "prefix:*", sub {
    my ($connection, $key) = @_;
    ...
  });

Execute callback exactly once for every key matching a pattern
(of "*" if none given). L</scan> is used internally.

C<$_> is localized and set to the key so shorter callbacks can be used.

Callback arguments are ($r, $key).

=head2 sort

  $r->sort(key, [BY pattern], [LIMIT offset count], [GET pattern [GET pattern ...]], [ASC|DESC], [ALPHA], [STORE destination])

Sort the elements in a list, set or sorted set (see L<https://redis.io/commands/sort>)

=head2 ttl

  $r->ttl(key)

Get the time to live for a key (see L<https://redis.io/commands/ttl>)

=head2 type

  $r->type(key)

Determine the type stored at key (see L<https://redis.io/commands/type>)

=head1 STRINGS

=head2 append

  $r->append(key, value)

Append a value to a key (see L<https://redis.io/commands/append>)

=head2 bitcount

  $r->bitcount(key, [start end])

Count set bits in a string (see L<https://redis.io/commands/bitcount>)

=head2 bitop

  $r->bitop(operation, destkey, key [key ...])

Perform bitwise operations between strings (see L<https://redis.io/commands/bitop>)

=head2 bitpos

  $r->bitpos(key, bit, [start], [end])

Find first bit set or clear in a string (see L<https://redis.io/commands/bitpos>)

=head2 blpop

  $r->blpop(key [key ...], timeout)

Remove and get the first element in a list, or block until one is available (see L<https://redis.io/commands/blpop>)

=head2 brpop

  $r->brpop(key [key ...], timeout)

Remove and get the last element in a list, or block until one is available (see L<https://redis.io/commands/brpop>)

=head2 brpoplpush

  $r->brpoplpush(source, destination, timeout)

Pop a value from a list, push it to another list and return it; or block until one is available (see L<https://redis.io/commands/brpoplpush>)

=head2 decr

  $r->decr(key)

Decrement the integer value of a key by one (see L<https://redis.io/commands/decr>)

=head2 decrby

  $r->decrby(key, decrement)

Decrement the integer value of a key by the given number (see L<https://redis.io/commands/decrby>)

=head2 get

  $r->get(key)

Get the value of a key (see L<https://redis.io/commands/get>)

=head2 getbit

  $r->getbit(key, offset)

Returns the bit value at offset in the string value stored at key (see L<https://redis.io/commands/getbit>)

=head2 getrange

  $r->getrange(key, start, end)

Get a substring of the string stored at a key (see L<https://redis.io/commands/getrange>)

=head2 getset

  $r->getset(key, value)

Set the string value of a key and return its old value (see L<https://redis.io/commands/getset>)

=head2 incr

  $r->incr(key)

Increment the integer value of a key by one (see L<https://redis.io/commands/incr>)

=head2 incrby

  $r->incrby(key, increment)

Increment the integer value of a key by the given amount (see L<https://redis.io/commands/incrby>)

=head2 incrbyfloat

  $r->incrbyfloat(key, increment)

Increment the float value of a key by the given amount (see L<https://redis.io/commands/incrbyfloat>)

=head2 mget

  $r->mget(key [key ...])

Get the values of all the given keys (see L<https://redis.io/commands/mget>)

=head2 mset

  $r->mset(key value [key value ...])

Set multiple keys to multiple values (see L<https://redis.io/commands/mset>)

=head2 msetnx

  $r->msetnx(key value [key value ...])

Set multiple keys to multiple values, only if none of the keys exist (see L<https://redis.io/commands/msetnx>)

=head2 psetex

  $r->psetex(key, milliseconds, value)

Set the value and expiration in milliseconds of a key (see L<https://redis.io/commands/psetex>)

=head2 set

  $r->set(key, value, ['EX',  seconds], ['PX', milliseconds], ['NX'|'XX'])

Set the string value of a key (see L<https://redis.io/commands/set>). Example:

  $r->set('key', 'test', 'EX', 60, 'NX')

=head2 setbit

  $r->setbit(key, offset, value)

Sets or clears the bit at offset in the string value stored at key (see L<https://redis.io/commands/setbit>)

=head2 setex

  $r->setex(key, seconds, value)

Set the value and expiration of a key (see L<https://redis.io/commands/setex>)

=head2 setnx

  $r->setnx(key, value)

Set the value of a key, only if the key does not exist (see L<https://redis.io/commands/setnx>)

=head2 setrange

  $r->setrange(key, offset, value)

Overwrite part of a string at key starting at the specified offset (see L<https://redis.io/commands/setrange>)

=head2 strlen

  $r->strlen(key)

Get the length of the value stored in a key (see L<https://redis.io/commands/strlen>)

=head1 HASHES

=head2 hdel

  $r->hdel(key, field [field ...])

Delete one or more hash fields (see L<https://redis.io/commands/hdel>)

=head2 hexists

  $r->hexists(key, field)

Determine if a hash field exists (see L<https://redis.io/commands/hexists>)

=head2 hget

  $r->hget(key, field)

Get the value of a hash field (see L<https://redis.io/commands/hget>)

=head2 hgetall

  $r->hgetall(key)

Get all the fields and values in a hash (see L<https://redis.io/commands/hgetall>)

=head2 hincrby

  $r->hincrby(key, field, increment)

Increment the integer value of a hash field by the given number (see L<https://redis.io/commands/hincrby>)

=head2 hincrbyfloat

  $r->hincrbyfloat(key, field, increment)

Increment the float value of a hash field by the given amount (see L<https://redis.io/commands/hincrbyfloat>)

=head2 hkeys

  $r->hkeys(key)

Get all the fields in a hash (see L<https://redis.io/commands/hkeys>)

=head2 hlen

  $r->hlen(key)

Get the number of fields in a hash (see L<https://redis.io/commands/hlen>)

=head2 hmget

  $r->hmget(key, field [field ...])

Get the values of all the given hash fields (see L<https://redis.io/commands/hmget>)

=head2 hmset

  $r->hmset(key, field value [field value ...])

Set multiple hash fields to multiple values (see L<https://redis.io/commands/hmset>)

=head2 hscan

  $r->hscan(key, cursor, [MATCH pattern], [COUNT count])

Incrementally iterate hash fields and associated values (see L<https://redis.io/commands/hscan>)

=head2 hset

  $r->hset(key, field, value)

Set the string value of a hash field (see L<https://redis.io/commands/hset>)

=head2 hsetnx

  $r->hsetnx(key, field, value)

Set the value of a hash field, only if the field does not exist (see L<https://redis.io/commands/hsetnx>)

=head2 hvals

  $r->hvals(key)

Get all the values in a hash (see L<https://redis.io/commands/hvals>)

=head1 SETS

=head2 sadd

  $r->sadd(key, member [member ...])

Add one or more members to a set (see L<https://redis.io/commands/sadd>)

=head2 scard

  $r->scard(key)

Get the number of members in a set (see L<https://redis.io/commands/scard>)

=head2 sdiff

  $r->sdiff(key [key ...])

Subtract multiple sets (see L<https://redis.io/commands/sdiff>)

=head2 sdiffstore

  $r->sdiffstore(destination, key [key ...])

Subtract multiple sets and store the resulting set in a key (see L<https://redis.io/commands/sdiffstore>)

=head2 sinter

  $r->sinter(key [key ...])

Intersect multiple sets (see L<https://redis.io/commands/sinter>)

=head2 sinterstore

  $r->sinterstore(destination, key [key ...])

Intersect multiple sets and store the resulting set in a key (see L<https://redis.io/commands/sinterstore>)

=head2 sismember

  $r->sismember(key, member)

Determine if a given value is a member of a set (see L<https://redis.io/commands/sismember>)

=head2 smembers

  $r->smembers(key)

Get all the members in a set (see L<https://redis.io/commands/smembers>)

=head2 smove

  $r->smove(source, destination, member)

Move a member from one set to another (see L<https://redis.io/commands/smove>)

=head2 spop

  $r->spop(key)

Remove and return a random member from a set (see L<https://redis.io/commands/spop>)

=head2 srandmember

  $r->srandmember(key, [count])

Get one or multiple random members from a set (see L<https://redis.io/commands/srandmember>)

=head2 srem

  $r->srem(key, member [member ...])

Remove one or more members from a set (see L<https://redis.io/commands/srem>)

=head2 sscan

  $r->sscan(key, cursor, [MATCH pattern], [COUNT count])

Incrementally iterate Set elements (see L<https://redis.io/commands/sscan>)

=head2 sunion

  $r->sunion(key [key ...])

Add multiple sets (see L<https://redis.io/commands/sunion>)

=head2 sunionstore

  $r->sunionstore(destination, key [key ...])

Add multiple sets and store the resulting set in a key (see L<https://redis.io/commands/sunionstore>)

=head1 SORTED SETS

=head2 zadd

  $r->zadd(key, score member [score member ...])

Add one or more members to a sorted set, or update its score if it already exists (see L<https://redis.io/commands/zadd>)

=head2 zcard

  $r->zcard(key)

Get the number of members in a sorted set (see L<https://redis.io/commands/zcard>)

=head2 zcount

  $r->zcount(key, min, max)

Count the members in a sorted set with scores within the given values (see L<https://redis.io/commands/zcount>)

=head2 zincrby

  $r->zincrby(key, increment, member)

Increment the score of a member in a sorted set (see L<https://redis.io/commands/zincrby>)

=head2 zinterstore

  $r->zinterstore(destination, numkeys, key [key ...], [WEIGHTS weight [weight ...]], [AGGREGATE SUM|MIN|MAX])

Intersect multiple sorted sets and store the resulting sorted set in a new key (see L<https://redis.io/commands/zinterstore>)

=head2 zlexcount

  $r->zlexcount(key, min, max)

Count the number of members in a sorted set between a given lexicographical range (see L<https://redis.io/commands/zlexcount>)

=head2 zrange

  $r->zrange(key, start, stop, [WITHSCORES])

Return a range of members in a sorted set, by index (see L<https://redis.io/commands/zrange>)

=head2 zrangebylex

  $r->zrangebylex(key, min, max, [LIMIT offset count])

Return a range of members in a sorted set, by lexicographical range (see L<https://redis.io/commands/zrangebylex>)

=head2 zrangebyscore

  $r->zrangebyscore(key, min, max, [WITHSCORES], [LIMIT offset count])

Return a range of members in a sorted set, by score (see L<https://redis.io/commands/zrangebyscore>)

=head2 zrank

  $r->zrank(key, member)

Determine the index of a member in a sorted set (see L<https://redis.io/commands/zrank>)

=head2 zrem

  $r->zrem(key, member [member ...])

Remove one or more members from a sorted set (see L<https://redis.io/commands/zrem>)

=head2 zremrangebylex

  $r->zremrangebylex(key, min, max)

Remove all members in a sorted set between the given lexicographical range (see L<https://redis.io/commands/zremrangebylex>)

=head2 zremrangebyrank

  $r->zremrangebyrank(key, start, stop)

Remove all members in a sorted set within the given indexes (see L<https://redis.io/commands/zremrangebyrank>)

=head2 zremrangebyscore

  $r->zremrangebyscore(key, min, max)

Remove all members in a sorted set within the given scores (see L<https://redis.io/commands/zremrangebyscore>)

=head2 zrevrange

  $r->zrevrange(key, start, stop, [WITHSCORES])

Return a range of members in a sorted set, by index, with scores ordered from high to low (see L<https://redis.io/commands/zrevrange>)

=head2 zrevrangebylex

  $r->zrevrangebylex(key, max, min, [LIMIT offset count])

Return a range of members in a sorted set, by lexicographical range, ordered from higher to lower strings. (see L<https://redis.io/commands/zrevrangebylex>)

=head2 zrevrangebyscore

  $r->zrevrangebyscore(key, max, min, [WITHSCORES], [LIMIT offset count])

Return a range of members in a sorted set, by score, with scores ordered from high to low (see L<https://redis.io/commands/zrevrangebyscore>)

=head2 zrevrank

  $r->zrevrank(key, member)

Determine the index of a member in a sorted set, with scores ordered from high to low (see L<https://redis.io/commands/zrevrank>)

=head2 zscan

  $r->zscan(key, cursor, [MATCH pattern], [COUNT count])

Incrementally iterate sorted sets elements and associated scores (see L<https://redis.io/commands/zscan>)

=head2 zscore

  $r->zscore(key, member)

Get the score associated with the given member in a sorted set (see L<https://redis.io/commands/zscore>)

=head2 zunionstore

  $r->zunionstore(destination, numkeys, key [key ...], [WEIGHTS weight [weight ...]], [AGGREGATE SUM|MIN|MAX])

Add multiple sorted sets and store the resulting sorted set in a new key (see L<https://redis.io/commands/zunionstore>)

=head1 HYPERLOGLOG

=head2 pfadd

  $r->pfadd(key, element [element ...])

Adds the specified elements to the specified HyperLogLog. (see L<https://redis.io/commands/pfadd>)

=head2 pfcount

  $r->pfcount(key [key ...])

Return the approximated cardinality of the set(s) observed by the HyperLogLog at key(s). (see L<https://redis.io/commands/pfcount>)

=head2 pfmerge

  $r->pfmerge(destkey, sourcekey [sourcekey ...])

Merge N different HyperLogLogs into a single one. (see L<https://redis.io/commands/pfmerge>)

=head1 PUB/SUB

=head2 pubsub

  $r->pubsub(subcommand, [argument [argument ...]])

Inspect the state of the Pub/Sub subsystem (see L<https://redis.io/commands/pubsub>)

=head1 TRANSACTIONS

=head2 discard

  $r->discard()

Discard all commands issued after MULTI (see L<https://redis.io/commands/discard>)

=head2 exec

  $r->exec()

Execute all commands issued after MULTI (see L<https://redis.io/commands/exec>)

=head2 multi

  $r->multi()

Mark the start of a transaction block (see L<https://redis.io/commands/multi>)

=head2 unwatch

  $r->unwatch()

Forget about all watched keys (see L<https://redis.io/commands/unwatch>)

=head2 watch

  $r->watch(key [key ...])

Watch the given keys to determine execution of the MULTI/EXEC block (see L<https://redis.io/commands/watch>)

=head1 SCRIPTING

=head2 eval

  $r->eval(script, numkeys, key [key ...], arg [arg ...])

Execute a Lua script server side (see L<https://redis.io/commands/eval>)

=head2 evalsha

  $r->evalsha(sha1, numkeys, key [key ...], arg [arg ...])

Execute a Lua script server side (see L<https://redis.io/commands/evalsha>)

=head2 script_exists

  $r->script_exists(script [script ...])

Check existence of scripts in the script cache. (see L<https://redis.io/commands/script-exists>)

=head2 script_flush

  $r->script_flush()

Remove all the scripts from the script cache. (see L<https://redis.io/commands/script-flush>)

=head2 script_kill

  $r->script_kill()

Kill the script currently in execution. (see L<https://redis.io/commands/script-kill>)

=head2 script_load

  $r->script_load(script)

Load the specified Lua script into the script cache. (see L<https://redis.io/commands/script-load>)

=head1 CONNECTION

=head2 auth

  $r->auth(password)

Authenticate to the server (see L<https://redis.io/commands/auth>)

  $r->auth(username, password)

Authenticate to the server using Redis 6.0+ ACL System (see L<https://redis.io/commands/auth>)

=head2 echo

  $r->echo(message)

Echo the given string (see L<https://redis.io/commands/echo>)

=head2 ping

  $r->ping()

Ping the server (see L<https://redis.io/commands/ping>)

=head2 quit

  $r->quit()

Close the connection (see L<https://redis.io/commands/quit>)

=head2 select

  $r->select(index)

Change the selected database for the current connection (see L<https://redis.io/commands/select>)

=head1 SERVER

=head2 bgrewriteaof

  $r->bgrewriteaof()

Asynchronously rewrite the append-only file (see L<https://redis.io/commands/bgrewriteaof>)

=head2 bgsave

  $r->bgsave()

Asynchronously save the dataset to disk (see L<https://redis.io/commands/bgsave>)

=head2 client_getname

  $r->client_getname()

Get the current connection name (see L<https://redis.io/commands/client-getname>)

=head2 client_kill

  $r->client_kill([ip:port], [ID client-id], [TYPE normal|slave|pubsub], [ADDR ip:port], [SKIPME yes/no])

Kill the connection of a client (see L<https://redis.io/commands/client-kill>)

=head2 client_list

  $r->client_list()

Get the list of client connections (see L<https://redis.io/commands/client-list>)

=head2 client_pause

  $r->client_pause(timeout)

Stop processing commands from clients for some time (see L<https://redis.io/commands/client-pause>)

=head2 client_setname

  $r->client_setname(connection-name)

Set the current connection name (see L<https://redis.io/commands/client-setname>)

=head2 cluster_slots

  $r->cluster_slots()

Get array of Cluster slot to node mappings (see L<https://redis.io/commands/cluster-slots>)

=head2 command

  $r->command()

Get array of Redis command details (see L<https://redis.io/commands/command>)

=head2 command_count

  $r->command_count()

Get total number of Redis commands (see L<https://redis.io/commands/command-count>)

=head2 command_getkeys

  $r->command_getkeys()

Extract keys given a full Redis command (see L<https://redis.io/commands/command-getkeys>)

=head2 command_info

  $r->command_info(command-name [command-name ...])

Get array of specific Redis command details (see L<https://redis.io/commands/command-info>)

=head2 config_get

  $r->config_get(parameter)

Get the value of a configuration parameter (see L<https://redis.io/commands/config-get>)

=head2 config_resetstat

  $r->config_resetstat()

Reset the stats returned by INFO (see L<https://redis.io/commands/config-resetstat>)

=head2 config_rewrite

  $r->config_rewrite()

Rewrite the configuration file with the in memory configuration (see L<https://redis.io/commands/config-rewrite>)

=head2 config_set

  $r->config_set(parameter, value)

Set a configuration parameter to the given value (see L<https://redis.io/commands/config-set>)

=head2 dbsize

  $r->dbsize()

Return the number of keys in the selected database (see L<https://redis.io/commands/dbsize>)

=head2 debug_object

  $r->debug_object(key)

Get debugging information about a key (see L<https://redis.io/commands/debug-object>)

=head2 debug_segfault

  $r->debug_segfault()

Make the server crash (see L<https://redis.io/commands/debug-segfault>)

=head2 flushall

  $r->flushall()

Remove all keys from all databases (see L<https://redis.io/commands/flushall>)

=head2 flushdb

  $r->flushdb()

Remove all keys from the current database (see L<https://redis.io/commands/flushdb>)

=head2 info

  $r->info([section])

Get information and statistics about the server (see L<https://redis.io/commands/info>)

=head2 lastsave

  $r->lastsave()

Get the UNIX time stamp of the last successful save to disk (see L<https://redis.io/commands/lastsave>)

=head2 lindex

  $r->lindex(key, index)

Get an element from a list by its index (see L<https://redis.io/commands/lindex>)

=head2 linsert

  $r->linsert(key, BEFORE|AFTER, pivot, value)

Insert an element before or after another element in a list (see L<https://redis.io/commands/linsert>)

=head2 llen

  $r->llen(key)

Get the length of a list (see L<https://redis.io/commands/llen>)

=head2 lpop

  $r->lpop(key)

Remove and get the first element in a list (see L<https://redis.io/commands/lpop>)

=head2 lpush

  $r->lpush(key, value [value ...])

Prepend one or multiple values to a list (see L<https://redis.io/commands/lpush>)

=head2 lpushx

  $r->lpushx(key, value)

Prepend a value to a list, only if the list exists (see L<https://redis.io/commands/lpushx>)

=head2 lrange

  $r->lrange(key, start, stop)

Get a range of elements from a list (see L<https://redis.io/commands/lrange>)

=head2 lrem

  $r->lrem(key, count, value)

Remove elements from a list (see L<https://redis.io/commands/lrem>)

=head2 lset

  $r->lset(key, index, value)

Set the value of an element in a list by its index (see L<https://redis.io/commands/lset>)

=head2 ltrim

  $r->ltrim(key, start, stop)

Trim a list to the specified range (see L<https://redis.io/commands/ltrim>)

=head2 monitor

  $r->monitor()

Listen for all requests received by the server in real time (see L<https://redis.io/commands/monitor>)

=head2 role

  $r->role()

Return the role of the instance in the context of replication (see L<https://redis.io/commands/role>)

=head2 rpop

  $r->rpop(key)

Remove and get the last element in a list (see L<https://redis.io/commands/rpop>)

=head2 rpoplpush

  $r->rpoplpush(source, destination)

Remove the last element in a list, append it to another list and return it (see L<https://redis.io/commands/rpoplpush>)

=head2 rpush

  $r->rpush(key, value [value ...])

Append one or multiple values to a list (see L<https://redis.io/commands/rpush>)

=head2 rpushx

  $r->rpushx(key, value)

Append a value to a list, only if the list exists (see L<https://redis.io/commands/rpushx>)

=head2 save

  $r->save()

Synchronously save the dataset to disk (see L<https://redis.io/commands/save>)

=head2 shutdown

  $r->shutdown([NOSAVE], [SAVE])

Synchronously save the dataset to disk and then shut down the server (see L<https://redis.io/commands/shutdown>)

=head2 slaveof

  $r->slaveof(host, port)

Make the server a slave of another instance, or promote it as master (see L<https://redis.io/commands/slaveof>)

=head2 slowlog

  $r->slowlog(subcommand, [argument])

Manages the Redis slow queries log (see L<https://redis.io/commands/slowlog>)

=head2 sync

  $r->sync()

Internal command used for replication (see L<https://redis.io/commands/sync>)

=head2 time

  $r->time()

Return the current server time (see L<https://redis.io/commands/time>)

=head1 ACKNOWLEDGEMENTS

The following persons contributed to this project (random order):

=over

=item *

Aaron Crane (pipelining and AUTOLOAD caching support)

=item *

Dirk Vleugels

=item *

Flavio Poletti

=item *

Jeremy Zawodny

=item *

sunnavy at bestpractical.com

=item *

Thiago Berlitz Rondon

=item *

Ulrich Habel

=item *

Ivan Kruglov

=item *

Steffen Mueller <smueller@cpan.org>

=back

=cut
