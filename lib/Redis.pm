package Redis;

use warnings;
use strict;

use IO::Socket::INET;
use Data::Dump qw/dump/;
use Carp qw/confess/;

=head1 NAME

Redis - perl binding for Redis database

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Pure perl bindings for L<http://code.google.com/p/redis/>

This version support git version of Redis available at
L<git://github.com/antirez/redis>

    use Redis;

    my $r = Redis->new();

=head1 FUNCTIONS

=head2 new

=cut

our $debug = $ENV{REDIS} || 0;

our $sock;
my $server = '127.0.0.1:6379';

sub new {
	my $class = shift;
	my $self = {};
	bless($self, $class);

	warn "# opening socket to $server";

	$sock ||= IO::Socket::INET->new(
		PeerAddr => $server,
		Proto => 'tcp',
	) || die $!;

	$self;
}

sub __sock_result {
	my $result = <$sock>;
	warn "## result: ",dump( $result ) if $debug;
	$result =~ s{\r\n$}{} || warn "can't find cr/lf";
	return $result;
}

sub __sock_read_bulk {
	my $len = <$sock>;
	warn "## bulk len: ",dump($len) if $debug;
	return undef if $len eq "nil\r\n";
	my $v;
	if ( $len > 0 ) {
		read($sock, $v, $len) || die $!;
		warn "## bulk v: ",dump($v) if $debug;
	}
	my $crlf;
	read($sock, $crlf, 2); # skip cr/lf
	return $v;
}

sub _sock_result_bulk {
	my $self = shift;
	warn "## _sock_result_bulk ",dump( @_ ) if $debug;
	print $sock join(' ',@_) . "\r\n";
	__sock_read_bulk();
}

sub _sock_result_bulk_list {
	my $self = shift;
	warn "## _sock_result_bulk_list ",dump( @_ ) if $debug;

	my $size = $self->_sock_send( @_ );
	confess $size unless $size > 0;
	$size--;

	my @list = ( 0 .. $size );
	foreach ( 0 .. $size ) {
		$list[ $_ ] = __sock_read_bulk();
	}

	warn "## list = ", dump( @list ) if $debug;
	return @list;
}

sub __sock_ok {
	my $ok = <$sock>;
	return undef if $ok eq "nil\r\n";
	confess dump($ok) unless $ok eq "+OK\r\n";
}

sub _sock_send {
	my $self = shift;
	warn "## _sock_send ",dump( @_ ) if $debug;
	print $sock join(' ',@_) . "\r\n";
	__sock_result();
}

sub _sock_send_ok {
	my $self = shift;
	warn "## _sock_send_ok ",dump( @_ ) if $debug;
	print $sock join(' ',@_) . "\r\n";
	__sock_ok();
}

sub __sock_send_bulk_raw {
	warn "## _sock_send_bulk ",dump( @_ ) if $debug;
	my $value = pop;
	$value = '' unless defined $value; # FIXME errr? nil?
	print $sock join(' ',@_) . ' ' . length($value) . "\r\n$value\r\n"
}

sub _sock_send_bulk {
	my $self = shift;
	__sock_send_bulk_raw( @_ );
	__sock_ok();
}

sub _sock_send_bulk_number {
	my $self = shift;
	__sock_send_bulk_raw( @_ );
	my $v = __sock_result();
	confess $v unless $v =~ m{^\-?\d+$};
	return $v;
}

=head1 Connection Handling

=head2 quit

  $r->quit;

=cut

sub quit {
	my $self = shift;

	close( $sock ) || warn $!;
}

=head2 ping

  $r->ping || die "no server?";

=cut

sub ping {
	print $sock "PING\r\n";
	my $pong = <$sock>;
	die "ping failed, got ", dump($pong) unless $pong eq "+PONG\r\n";
}

=head1 Commands operating on string values

=head2 set

  $r->set( foo => 'bar', $new );

=cut

sub set {
	my ( $self, $key, $value, $new ) = @_;
	$self->_sock_send_bulk( "SET" . ( $new ? 'NX' : '' ), $key, $value );
}

=head2 get

  my $value = $r->get( 'foo' );

=cut

sub get {
	my $self = shift;
	$self->_sock_result_bulk('GET',@_);
}

=head2 mget

  my @values = $r->get( 'foo', 'bar', 'baz' );

=cut

sub mget {
	my $self = shift;
	$self->_sock_result_bulk_list('MGET',@_);
}

=head2 incr

  $r->incr('counter');
  $r->incr('tripplets', 3);

=cut

	

sub incr {
	my $self = shift;
	$self->_sock_send( 'INCR' . ( $#_ ? 'BY' : '' ), @_ );
}

=head2 decr

  $r->decr('counter');
  $r->decr('tripplets', 3);

=cut

sub decr {
	my $self = shift;
	$self->_sock_send( 'DECR' . ( $#_ ? 'BY' : '' ), @_ );
}

=head2 exists

  $r->exists( 'key' ) && print "got key!";

=cut

sub exists {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'EXISTS', $key );
}

=head2 del

  $r->del( 'key' ) || warn "key doesn't exist";

=cut

sub del {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'DEL', $key );
}

=head2 type

  $r->type( 'key' ); # = string

=cut

sub type {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'TYPE', $key );
}

=head1 Commands operating on the key space

=head2 keys

  my @keys = $r->keys( '*glob_pattern*' );

=cut

sub keys {
	my ( $self, $glob ) = @_;
	my $keys = $self->_sock_result_bulk( 'KEYS', $glob );
	return split(/\s/, $keys) if $keys;
	return () if wantarray;
}

=head2 randomkey

  my $key = $r->randomkey;

=cut

sub randomkey {
	my ( $self ) = @_;
	$self->_sock_send( 'RANDOMKEY' );
}

=head2 rename

  my $ok = $r->rename( 'old-key', 'new-key', $new );

=cut

sub rename {
	my ( $self, $old, $new, $nx ) = @_;
	$self->_sock_send_ok( 'RENAME' . ( $nx ? 'NX' : '' ), $old, $new );
}

=head2 dbsize

  my $nr_keys = $r->dbsize;

=cut

sub dbsize {
	my ( $self ) = @_;
	$self->_sock_send('DBSIZE');
}

=head1 Commands operating on lists

See also L<Redis::List> for tie interface.

=head2 rpush

  $r->rpush( $key, $value );

=cut

sub rpush {
	my ( $self, $key, $value ) = @_;
	$self->_sock_send_bulk('RPUSH', $key, $value);
}

=head2 lpush

  $r->lpush( $key, $value );

=cut

sub lpush {
	my ( $self, $key, $value ) = @_;
	$self->_sock_send_bulk('LPUSH', $key, $value);
}

=head2 llen

  $r->llen( $key );

=cut

sub llen {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'LLEN', $key );
}

=head2 lrange

  my @list = $r->lrange( $key, $start, $end );

=cut

sub lrange {
	my ( $self, $key, $start, $end ) = @_;
	$self->_sock_result_bulk_list('LRANGE', $key, $start, $end);
}

=head2 ltrim

  my $ok = $r->ltrim( $key, $start, $end );

=cut

sub ltrim {
	my ( $self, $key, $start, $end ) = @_;
	$self->_sock_send_ok( 'LTRIM', $key, $start, $end );
}

=head2 lindex

  $r->lindex( $key, $index );

=cut

sub lindex {
	my ( $self, $key, $index ) = @_;
	$self->_sock_result_bulk( 'LINDEX', $key, $index );
}

=head2 lset

  $r->lset( $key, $index, $value );

=cut

sub lset {
	my ( $self, $key, $index, $value ) = @_;
	$self->_sock_send_bulk( 'LSET', $key, $index, $value );
}

=head2 lrem

  my $modified_count = $r->lrem( $key, $count, $value );

=cut

sub lrem {
	my ( $self, $key, $count, $value ) = @_;
	$self->_sock_send_bulk_number( 'LREM', $key, $count, $value );
}

=head2 lpop

  my $value = $r->lpop( $key );

=cut

sub lpop {
	my ( $self, $key ) = @_;
	$self->_sock_result_bulk( 'LPOP', $key );
}

=head2 rpop

  my $value = $r->rpop( $key );

=cut

sub rpop {
	my ( $self, $key ) = @_;
	$self->_sock_result_bulk( 'RPOP', $key );
}

=head1 Commands operating on sets

=head2 sadd

  $r->sadd( $key, $member );

=cut

sub sadd {
	my ( $self, $key, $member ) = @_;
	$self->_sock_send_bulk_number( 'SADD', $key, $member );
}

=head2 srem

  $r->srem( $key, $member );

=cut

sub srem {
	my ( $self, $key, $member ) = @_;
	$self->_sock_send_bulk_number( 'SREM', $key, $member );
}

=head2 scard

  my $elements = $r->scard( $key );

=cut

sub scard {
	my ( $self, $key ) = @_;
	$self->_sock_send( 'SCARD', $key );
}

=head2 sismember

  $r->sismember( $key, $member );

=cut

sub sismember {
	my ( $self, $key, $member ) = @_;
	$self->_sock_send_bulk_number( 'SISMEMBER', $key, $member );
}

=head2 sinter

  $r->sinter( $key1, $key2, ... );

=cut

sub sinter {
	my $self = shift;
	$self->_sock_result_bulk_list( 'SINTER', @_ );
}

=head2 sinterstore

  my $ok = $r->sinterstore( $dstkey, $key1, $key2, ... );

=cut

sub sinterstore {
	my $self = shift;
	$self->_sock_send_ok( 'SINTERSTORE', @_ );
}

=head1 Multiple databases handling commands

=head2 select

  $r->select( $dbindex ); # 0 for new clients

=cut

sub select {
	my ($self,$dbindex) = @_;
	confess dump($dbindex) . 'not number' unless $dbindex =~ m{^\d+$};
	$self->_sock_send_ok( 'SELECT', $dbindex );
}

=head2 move

  $r->move( $key, $dbindex );

=cut

sub move {
	my ( $self, $key, $dbindex ) = @_;
	$self->_sock_send( 'MOVE', $key, $dbindex );
}

=head2 flushdb

  $r->flushdb;

=cut

sub flushdb {
	my $self = shift;
	$self->_sock_send_ok('FLUSHDB');
}

=head2 flushall

  $r->flushall;

=cut

sub flushall {
	my $self = shift;
	$self->_sock_send_ok('flushall');
}

=head1 AUTHOR

Dobrica Pavlinusic, C<< <dpavlin at rot13.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-redis at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Redis>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Redis


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

Copyright 2009 Dobrica Pavlinusic, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Redis
