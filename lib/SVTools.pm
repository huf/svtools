package App::SVTools;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT = qw/
	common_options
	read_sv
	write_sv_row
	write_sv_end
/;

our $VERSION = '0.1';

use Getopt::Long;
Getopt::Long::Configure ("bundling");

my $USAGE = "[options] [files...]";
my @OPT_SPEC = qw/
	help|h
	version|V
	oenc|o=s
	table=s@
/;
my %OPTIONS;

my $SVSEE_PID;

my @TABLES;

sub common_options {
	my %p = @_;
	push @OPT_SPEC, @{ $p{opt_spec} } if $p{opt_spec};
	
	$USAGE = $p{usage} if $p{usage};

	push @OPT_SPEC, 'machine|m' unless $p{no_svsee};
	push @OPT_SPEC, 'ienc|i=s' if $p{need_ienc};

	GetOptions(\%OPTIONS, @OPT_SPEC)
		or die usage();
	
	die usage() if $OPTIONS{help};
	die "$0 $VERSION\n" if $OPTIONS{version};

	$OPTIONS{oenc} ||= 'UTF-8';
	$OPTIONS{ienc} ||= 'UTF-8';

	if ($OPTIONS{table}) {
		my $i = 0;
		for my $tdef (@{ $OPTIONS{table} }) {
			my ($tname, $colnames) = split /:/, $tdef, 2;
			my @cols;
			if ($colnames) {
				@cols = split /:/, $colnames;
			}
			$TABLES[$i] = {
				table => $tname,
				cols => \@cols,
			};
			$i++;
		}
	}

	if (@ARGV) {
		for (@ARGV) {
			push @TABLES, {
				table => $_,
				cols => [],
			};
		}
	}

	binmode \*STDIN, ":encoding($OPTIONS{ienc})";

	if (!$p{no_svsee} && -t STDOUT && !$OPTIONS{machine}) {
		swap_output_for_svsee($OPTIONS{oenc});
		binmode \*STDOUT, ':encoding(UTF-8)';
	}
	else {
		binmode \*STDOUT, ":encoding($OPTIONS{oenc})";
	}

	\%OPTIONS
}

sub swap_output_for_svsee {
	my ($oenc) = @_;

	pipe my $r, my $w or die "cannot pipe: $!\n";
	$SVSEE_PID = fork;
	die "cannot fork: $!\n" if $SVSEE_PID < 0;

	if ($SVSEE_PID) {
		open STDOUT, '>&', $w or die "cannot dup: $!";
	}
	else {
		my $bin = 'svsee';
		$bin = './bin/svsee' if -x './bin/svsee';
		my @args;
		push @args, "--oenc=$oenc";
		for my $t (@TABLES) {
			my $spec = $t->{table};
			$spec .= ':'.join ',', @{ $t->{cols} };
			push @args, "--table=$spec";
		}
		open STDIN, '<&', $r or die "cannot dup: $!";

		exec $bin, @args;
		die "cannot exec svsee\n";
	}
}

END {
	if ($SVSEE_PID) {
		close STDOUT;
		waitpid $SVSEE_PID, 0;
	}
}

sub usage {
	my $msg = qq{$0 $USAGE\n};
	$msg .= "    $_\n" for @OPT_SPEC;
	$msg
}	

sub read_sv {
	my %p = @_;
	if ($p{fh}) {
		read_sv_stream(inline_tables => 1, %p);
	}
	elsif ($p{files}) {
		my @files = @{ delete $p{files} };
		for my $f (@files) {
			open my $fh, '<', $f or die "cannot open $f: $!\n";
			read_sv_stream(table => $f, fh => $fh, %p);
		}
	}
	else {
		die "read_sv_stream fh => ... OR files => [ ... ]\n";
	}
}

my $TABLE_IDX = 0;

sub read_sv_stream {
	my %p = @_;
	local $/ = "\N{RS}";
	my $got_header = 0;
	my $table;
	my $table_name_n = 2;

	if (!$p{inline_tables} && $p{table}) {
		$table = $p{table};
	}

	$table = $TABLES[$TABLE_IDX++] || { table => 't', cols => [] };

	$p{on_table_start}->($table->{table}) if $p{on_table_start};

	while (my $r = readline $p{fh}) {
		last if $r eq "\N{FS}";
		chomp $r;
		if ($p{inline_tables} && substr($r, 0, 1) eq "\N{FS}") {
			$r = substr($r, 1);

			$p{on_table_end}->($table->{table}) if $p{on_table_end};
			$table = $TABLES[$TABLE_IDX++] || { table => 't'.$table_name_n++, cols => [] };
			$p{on_table_start}->($table->{table}) if $p{on_table_start};
			$got_header = 0;
		}
		my @row = split /\N{US}/, $r;
		if (!$got_header) {
			for (0..$#{ $table->{cols} }) {
				$row[$_] = $table->{cols}[$_];
			}
			$p{on_header}->(\@row) if $p{on_header};
			$got_header = 1;
		}
		else {
			$p{on_row}->(\@row) if $p{on_row};
		}
	}

	$p{on_table_end}->($table->{table}) if $p{on_table_end};
}

sub write_sv_row {
	my ($fh, $data) = @_;
	print {$fh} join("\N{US}", @$data), "\N{RS}";
}

sub write_sv_end {
	my $fh = shift;
	print {$fh} "\N{FS}";
}

1
