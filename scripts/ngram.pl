#!/usr/bin/perl

use warnings;
use strict;

use lib 'lib';
use Redis;
use Getopt::Long;
use Time::HiRes qw(time);
use Data::Dump qw(dump);

my $import;
my $len = 3;
my $max = 25;
my $cutoff = 0.75;
my $debug = 0;

GetOptions(
	'import=s' => \$import,
	'len=i'    => \$len,
	'max=i'    => \$max,
	'cutoff=f' => \$cutoff,
	'debug!'   => \$debug,
) || die $!;

my $redis = Redis->new;

sub ngram {
	my ( $string, $callback ) = @_;
	$string = lc $string;
	my $variants = length($string) - $len;
	foreach ( 0 .. $variants ) {
		my $ngram = substr($string,$_,$len);
		$callback->( "N$ngram" );
		warn "# $_ $ngram\n" if $debug;
	}
	return $variants + 1;
}

if ( $import ) {
	print STDERR "indexing $import ", -s $import, " bytes with $len ngram ";
	$redis->flushdb;
	open(my $fh, '<', $import) || die "$import: $!";
	while(<$fh>) {
		chomp;
		my $nr = $redis->rpush( 'lines' => $_ ) - 1; # -1 to convert into lindex index value
		ngram $_ => sub { $redis->sadd( $_[0] => $nr ) };
		warn "# line: $nr $_" if $debug;
		print STDERR "$nr " if $nr % 1000 == 0;
	}
	warn "finished ", $redis->llen('lines'), " lines\n";
}

print "search> ";

while(<STDIN>) {
	chomp;

	my $score;
	my $t = time;

	my $ngrams = ngram $_ => sub {
		my $ngram = shift;
		$score->{ $_ }++ foreach $redis->smembers( $ngram );
	};

	$t = time - $t;

	my $result = 0;

	foreach my $nr ( sort { $score->{$b} <=> $score->{$a} } keys %$score ) {
		my $relevance = $score->{$nr} / $ngrams;
		$result++;
		last if $result && $result > $max && $relevance < $cutoff;
		last if $result > $max;
		printf "%-2d %5d %1.2f %s\n", $result, $nr, $score->{$nr} / $ngrams, $redis->lindex( 'lines' => $nr );
	}

	printf "%.2f sec ngrams:%d cutoff:%.2f\nsearch> ", $t, $ngrams, $cutoff;
}
