#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib';
use Redis;
use Getopt::Long;
use Data::Dump qw(dump);

my $import;
my $len = 3;

GetOptions(
	'import=s' => \$import,
	'len=i'    => \$len,
) || die $!;

my $redis = Redis->new;

sub ngram {
	my ( $string, $callback ) = @_;
	foreach ( 0 .. length($string) - $len ) {
		$callback->( substr($string,$_,$len) );
	}
}

if ( $import ) {
	$redis->flushdb;
	my $nr = 0;
	open(my $fh, '<', $import) || die "$import: $!";
	while(<$fh>) {
		chomp;
		$nr++;
		$redis->set( $nr => $_ );
		ngram $_ => sub { $redis->sadd( $_[0] => $nr ) };
	}
	warn "indexed $import with $nr lines\n";
}

warn "# enter search:\n";

while(<>) {
	chomp;

	my $score;
	ngram $_ => sub {
		my $ngram = shift;
		$score->{ $_ }++ foreach $redis->smembers( $ngram );
		warn "# $ngram ",dump($score);
	};

	foreach my $nr ( sort { $score->{$a} <=> $score->{$b} } keys %$score ) {
		printf "%d %s [%d]\n", $nr, $redis->get($nr), $score->{$nr};
	}

}
