#!/usr/bin/env perl
#
# Run perldoc sync_zones.pl for full docs.
#
# To run on OpenBSD, install p5-Config-Any, p5-Net-OpenSSH, p5-List-MoreUtils, p5-Config-General

use warnings;
use strict;
use autodie;
use 5.010;

use Config::Any;
use Getopt::Long;
use Pod::Usage;
use Net::OpenSSH;
use File::Copy;
use File::Compare;

sub proc_masters {
    my ($cmasters) = @_;
    my $lists = [];

    if( ref($cmasters) eq 'HASH' ) {
        push @$lists, get_zones($cmasters);
    }
    elsif( ref($cmasters) eq 'ARRAY' ) {
        foreach my $master (@{$cmasters}) {
            push @$lists, get_zones($master);
        }
    }

    rem_conflicting($lists); 

    return $lists;
}

sub get_zones {
    my ($cmaster) = @_;

    my $ssh = Net::OpenSSH->new( $cmaster->{'ssh_host'},
                  user     => $cmaster->{'ssh_user'},
                  key_path => $cmaster->{'ssh_key_path'} );
    my @list = $ssh->capture($cmaster->{'list_command'});
    $ssh->error and
        die "remote list command failed: " . $ssh->error;

    @list = sort @list;
    chomp @list;

    return { 'priority' => $cmaster->{'priority'},
             'ip' => $cmaster->{'ip'},
             'zones' => \@list };
}

sub rem_conflicting {
    my ($rlists) = @_;
    use List::MoreUtils qw(firstidx uniq);

    # See if we have multiple priority values.
    my @priorities = map { $_->{'priority'} } @{$rlists};
    @priorities = uniq @priorities;
    @priorities = reverse sort @priorities;

    # If we have more than one priority, we must compare up the tree.
    if(@priorities > 1) {
        foreach my $i (0..$#priorities) {
            # We can stop if we already compared the next to last priority.
            last if not defined $priorities[$i + 1];

            # Create a combined list of zones from masters with a
            # higher (lower number) priority than us.
            my @hzones;
            foreach my $j ($i+1..$#priorities) {
                foreach my $rlist (@{$rlists}) {
                    if( $rlist->{'priority'} <= $priorities[$j] ) {
                        push @hzones, @{$rlist->{zones}};
                    }
                }
            }

            # Each zonelist of a given priority needs to be compared
            # against every zone in higher priority masters.
            # Delete the zone from the lower priority master list
            # if it is found to collide with a zone in the higher
            # priority master zone list.
            foreach my $rlist (@{$rlists}) {
                if( $rlist->{'priority'} == $priorities[$i] ) {
                    foreach my $z (@hzones) {
                        chomp $z;
                        my $zindex = firstidx { /\A$z\z/ } @{$rlist->{zones}};
                        if( $zindex >= 0 ) {
                            splice @{$rlist->{zones}}, $zindex, 1;
                        }
                    }
                }
            }
        }
    }

} # End rem_conflicting

sub merge_master_lists {
    my ($zlists) = @_;
    my $szlist = {};

    foreach my $zlist (@{$zlists}) {
        foreach my $zone (@{$zlist->{'zones'}}) {
            $szlist->{$zone} = $zlist->{'ip'};
        }
    }

    return $szlist;
}

sub output_conf {
    my ($zlist, $tmpfile, $zpath, $zext, $ct) = @_;

    open(my $fh, '>', $tmpfile);

    foreach my $z (sort keys %{$zlist}) {
        if( $ct eq 'bind' ) {
            print $fh "zone \"$z\" in { type slave; file \"" .
                $zpath . $z . $zext . "\"; masters { " . $zlist->{$z} .
                "; }; };\n";
        }
        elsif( $ct eq 'nsd' ) {
            print $fh "zone:\n" .
                      "  name: \"" . $z . "\"\n" .
                      "  zonefile: \"" . $zpath . $z . $zext . "\"\n" .
                      "  allow-notify: " . $zlist->{$z} . " NOKEY\n" .
                      "  request-xfr: " . $zlist->{$z} .  " NOKEY\n";
        }
        else {
            die "Unrecognized config type: " . $ct;
        }
    }
    close $fh;
}

# See perldoc Getopt::Long
my ($help, $config_file);
GetOptions ( 'help' => \$help,
             'file=s' => \$config_file );

if( defined $help ) {
    pod2usage(0);
}

if( not defined $config_file ) {
    $config_file = '/etc/sync_zones.conf';
}
if( not -e $config_file ) { pod2usage(1) }

my $cfg = Config::Any->load_files( { files => [ $config_file ],
                                     use_ext => 1 } );

my $masters = $cfg->[0]->{$config_file}->{'Master'};

# Get our list of Masters and their zones.
my $zonelists = proc_masters($masters);

# Create a single list of zones and master IPs.
my $szonelist = merge_master_lists($zonelists);

my $config_type = $cfg->[0]->{$config_file}->{'Local'}->{'config_type'};
my $tmpfile = $cfg->[0]->{$config_file}->{'Local'}->{'tmp_file'};
my $zpath = $cfg->[0]->{$config_file}->{'Local'}->{'zonefile_path'};
$zpath = '' if not defined $zpath;
my $zext = $cfg->[0]->{$config_file}->{'Local'}->{'zonefile_extension'};
my $reload_cmd = $cfg->[0]->{$config_file}->{'Local'}->{'reload_cmd'};
output_conf($szonelist, $tmpfile, $zpath, $zext, $config_type);

my $ofile = $cfg->[0]->{$config_file}->{'Local'}->{'output_file'};

# If the normal output file does not exist, we put our tmp
# file in place.  If it is, we check for changes and copy
# over if they aren't the same.
if( not -e $ofile or compare($tmpfile,$ofile)) {
    move($tmpfile,$ofile);
    system($reload_cmd);
}

1;
__END__

=head1 NAME

sync_zones - Syncronize authoritative zones from a master DNS server.

=head1 SYNOPSIS

sync_zones.pl -f sync_zones.conf

sync_zones.pl --help

=head1 Private Functions

=head2 merge_zones_mp ARRAYREF

Merge all zone data together that has a specified minimum priority.
Remember, lower number is higher priority.

