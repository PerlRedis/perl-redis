package Redis::Sentinels;

# ABSTRACT: Redis Sentinels connection interface
# VERSION
# AUTHORITY

use warnings;
use strict;
use Redis;
use Carp qw/confess/;

sub new {
  my ($class, %args) = @_;

  my $sent_addrs = $args{sentinels};
  if (not ref($sent_addrs) eq 'ARRAY' or not @$sent_addrs) {
    confess("Need 'sentinels' option as a list of sentinel addresses");
  }

  my $self = bless({
    sentinels => $args{sentinels},
    connect_options => $args{connect_options} || {},
    # The index of the next sentinel to try to connect to
    current_sentinel_idx => 0,
  }) => $class;

  return $self;
}

sub get_master_address {
  my ($self, $service_name) = @_;
  if (not defined $service_name) {
    confess("Need name of service to look up using Redis sentinels");
  }

  my $master_addr;
  while (not defined $master_addr) {
    my ($sentinel_conn, $sentinel_idx) = $self->_get_sentinel_connection;

    my $master_addr = [$sentinel_conn->sentinel("get-master-addr-by-name", $service_name)];

    if (not @$master_addr or not defined $master_addr->[0]) {
      # Try next one if not exhausted
      if (++$sentinel_idx > $#{ $self->{sentinels} }) {
        # sentinel list exhausted
        confess("Failed to look up master address for '$service_name' "
                . "from any Sentinel");
      }
      $master_addr = undef;
      next;
    }
    elsif ($master_addr->[0] eq 'IDONTKNOW') {
      confess("Failed to look up master address for '$service_name'. Sentinel '"
              . $self->{sentinels}[$sentinel_idx] . "' replied with 'IDONTKNOW'");
    }

    # If we hit this, then we have a valid master address, put Sentinel
    # at top of list.
    $self->_move_sentinel_to_front;
  } # end "while still no master address"

  return $master_addr;
}

sub _get_sentinel_connection {
  my ($self, $start_idx) = @_;
  
  $start_idx = 0 if not defined $start_idx;
  my $sentinels = $self->{sentinels};

  foreach my $sentinel_idx ($start_idx .. $#{$self->{sentinels}}) {
    my $sentinel_addr = $sentinels->[$sentinel_idx];

    my $conn;
    eval {
      $conn = Redis->new(
        cnx_timeout => 0.1, # shorter 100ms connect timeout by default for sentinels
        %{ $self->{connect_options} },
        server => $sentinel_addr,
      );
      1
    } or do {
      my $err = $@ || 'Zombie Error';
      next if $err =~ /^Could not connect/;
      die;
    };

    return($conn, $sentinel_idx);
  }

  confess("Failed to connect to any Redis Sentinels!");
}

sub _move_sentinel_to_front {
  my ($self, $sentinel_idx) = @_;
  return() if $sentinel_idx == 0;

  my $sentinels = $self->{sentinels};
  my $sent_addr = splice(@$sentinels, $sentinel_idx, 1);
  unshift @$sentinels, $sent_addr;
  return();
}

1;
