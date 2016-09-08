package PVE::Storage::Custom::DellPSPlugin;

use strict;
use warnings;
use Data::Dumper;
use IO::File;
use POSIX qw(ceil);
use PVE::Tools qw(run_command trim file_read_firstline dir_glob_regex);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::Telnet;

use base qw(PVE::Storage::Plugin);

sub getmultiplier {
    my ($unit) = @_;
    my $mp;  # Multiplier for unit
    if ($unit eq 'MB') {
	$mp = 1024*1024;
    } elsif ($unit eq 'GB'){
	$mp = 1024*1024*1024;
    } elsif ($unit eq 'TB') {
	$mp = 1024*1024*1024*1024;
    } else {
	$mp = 1024*1024*1024;
	warn "Bad size suffix \"$4\", assuming gigabytes";
    }
    return $mp;
}

sub dell_connect {
    my ($scfg) = @_;
    my $obj = new Net::Telnet(
	Host => $scfg->{adminaddr},
	#Dump_log => "/tmp/dellplugin.log",
	Input_log  => "/tmp/dell.log",
	Output_log => "/tmp/dell.log",
    );

    $obj->login($scfg->{login}, $scfg->{password});
    $obj->cmd('cli-settings events off');
    $obj->cmd('cli-settings formatoutput off');
    $obj->cmd('cli-settings confirmation off');
    $obj->cmd('cli-settings idlelogout off');
    $obj->cmd('cli-settings paging off');
    $obj->cmd('cli-settings reprintBadInput off');
    $obj->cmd('stty hardwrap off');
    return $obj;
}

sub dell_create_lun {
    my ($scfg, $cache, $name, $size) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd(sprintf('volume create %s %s pool %s thin-provision', $name, $size, $scfg->{'pool'}));
}

sub dell_configure_lun {
    my ($scfg, $cache, $name) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    # unrestricted-access. Rewrite for production
    $tn->cmd("volume select $name access create ipaddress *.*.*.* authmethod none");
    # PVE itself manages access to LUNs, so that's OK.
    $tn->cmd("volume select $name multihost-access enable");
}

sub dell_delete_lun {
    my ($scfg, $cache, $name) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd("volume delete $name");
}

sub dell_resize_lun {
    my ($scfg, $cache, $name, $size) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd("volume select $name size no-snap $size");
}

sub dell_create_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd("volume select $name snapshot create-now $snapname");
}

sub dell_delete_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd("volume select $name snapshot delete $snapname");
}

sub dell_rollback_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd("volume select $name snapshot select $snapname restore");
}

sub dell_list_luns {
    my ($scfg, $cache, $vmid, $vollist) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};
    my $res = [];

    my @out = $tn->cmd('volume show');
    for my $line (@out) {
	if ($line =~ /^(vm-(\d+)-disk-\d+)\s+(\d+)([GMT]B)/) {
            next if $vmid && $vmid != $2; # $vmid filter
            next if $vollist && !grep(/^$1$/,@$vollist); # $vollist filter
	    my $mp = getmultiplier($4);
	    push(@$res, {'volid' => $1, 'format' => 'raw', 'size' => $3*$mp, 'vmid' => $2});
        }
    }
    return $res;
}

sub dell_get_lun_target {
    my ($scfg, $cache, $name) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    my @out = $tn->cmd("volume select $name show");
    for my $line (@out) {
	next unless $line =~ m/^iSCSI Name: (.+)$/;
	return $1;
    }
    return 0;
}

sub dell_status {
    my ($scfg, $cache) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    my @out = $tn->cmd('show pool');
    for my $line (@out) {
	next unless ($line =~ m/(\w+)\s+\w+\s+\d+\s+\d+\s+([\d\.]+)([MGT]B)\s+([\d\.]+)([MGT]B)/);
	next unless ($1 eq $scfg->{'pool'});

	my $total = int($2*getmultiplier($3));
	my $free  = int($4*getmultiplier($5));
	my $used = $total-$free;
	return [$total, $free, $used, 1];
    }
}

sub multipath_enable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";

    # Skip if device exists
    return if -e "/dev/disk/by-id/dm-uuid-mpath-ip-". $scfg->{'groupaddr'} .":3260-iscsi-$target-lun-0";

    # Discover portal for new targets
    run_command(['/usr/bin/iscsiadm', '-m', 'discovery', '--portal', $scfg->{'groupaddr'} .':3260', '--discover']);

    # Login to target. Will produce warning if already logged in. But that's safe.
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--login']);

    sleep 1;

    # wait udev to settle divices
    run_command(['/sbin/udevadm', 'settle']);
    #force devmap reload to connect new device.
    run_command(['/sbin/multipath', '-r']);
}

sub multipath_disable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";

    # give some time for runned process to free device
    sleep 5;

    #disable selected target multipathing
    run_command(['/sbin/multipath', '-f', 'ip-'. $scfg->{'groupaddr'} .":3260-iscsi-$target-lun-0"]);

    # Logout from target
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--logout']);

}

# Configuration

# API version
sub api {
    return 1;
}

sub type {
    return 'dellps';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1, none => 1}, { images => 1 }],
    };
}

sub properties {
    return {
        groupaddr => {
            description => "Group address of storage (for iscsi mounts)",
            type => 'string', format => 'pve-storage-server',
        },
	adminaddr => {
	    description => "Management IP or DNS name of storage.",
	    type => 'string', format => 'pve-storage-server',
	},
	login => {
	    description => "login",
	    type => 'string',
	},
	password => {
	    description => "password",
	    type => 'string',
	},
    };
}

sub options {
    return {
	groupaddr => { fixed => 1 },
	pool  => { fixed => 1 },
	login => { fixed => 1 },
	password => { fixed => 1 },
	adminaddr => { fixed => 1 },
        nodes   => { optional => 1 },
	disable => { optional => 1 },
	content => { optional => 1 },
	shared  => { optional => 1 },
    }
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/vm-(\d+)-disk-\S+/) {
	return ('images', $volname, $1, undef, undef, undef, 'raw');
    } else {
	die "Invalid volume $volname";
    }
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "Direct attached device snapshot is not implemented" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $target = dell_get_lun_target($scfg, undef, $name) || die "Cannot get iscsi tagret name";

    my $path = "/dev/disk/by-id/dm-uuid-mpath-ip-". $scfg->{'groupaddr'} .":3260-iscsi-$target-lun-0";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "Creating base image is currently unimplemented";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "Cloning image is currently unimplemented";
}

# Seems like this method gets size in kilobytes somehow,
# while listing methost return bytes. That's strange.
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $luns = dell_list_luns($scfg, undef, $vmid);
    my $vols;
    for my $lun (@$luns) {
	$vols->{$lun->{'volid'}} = 1;
    }

    unless ($name) {
	for (my $i = 1; $i < 100; $i++) {
	    if (!$vols->{"vm-$vmid-disk-$i"}) {
		$name = "vm-$vmid-disk-$i";
		last;
	    }
	}
    }

    my $cache;
    # Convert to megabytes and grow on one megabyte boundary if needed
    dell_create_lun($scfg, $cache, $name, ceil($size/1024) . 'MB');
    dell_configure_lun($scfg, $cache, $name);
    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $wwn = $class->mp_get_wwn($scfg, $volname);

    dell_delete_lun($scfg, undef, $volname);
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = dell_list_luns($scfg, $cache, $vmid, $vollist);

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    return @{dell_status($scfg, $cache)};
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Activating '$volname'\n";

    $class->multipath_enable($scfg, $cache, $volname);

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Deactivating '$volname'\n";
    $class->multipath_disable($scfg, $cache, $volname);

    return 1;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    my $cache;
    dell_resize_lun($scfg, $cache, $volname, ceil($size/1024/1024) . 'MB');

    my $target = dell_get_lun_target($scfg, $cache, $volname) || die "Cannot get iscsi tagret name";
    # rescan target for changes
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--portal', $scfg->{'groupaddr'} .':3260', '--target', $target, '-R']);

    return 1;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cache;

    dell_create_snapshot($scfg, $cache, $volname, $snap);
    return 1;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cache;

    dell_rollback_snapshot($scfg, $cache, $volname, $snap);

    #size could be changed here? Check for device changes.
    my $target = dell_get_lun_target($scfg, $cache, $volname) || die "Cannot get iscsi tagret name";
    # rescan target for changes
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--portal', $scfg->{'groupaddr'} .':3260', '--target', $target, '-R']);

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cache;

    dell_delete_snapshot($scfg, $cache, $volname, $snap);
    return 1;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1 },
	sparseinit => { current => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname) {
	$key = 'snap';
    } else {
	$key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
