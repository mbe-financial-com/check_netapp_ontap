#!/usr/bin/perl

# Script name:      check_netapp_ontap.pl
# Version:          v3.03.200924
# Original author:  Murphy John
# Current author:   D'Haese Willem
# Contributors:     Yip Wai Peng, Anriot Alexandre, Charton Yannick, Goetheyn Tony, Malone Josh
# Purpose:          Checks NetApp ontapi clusters for various problems, like volume, aggregate, snapshot,
#                   quota, snapmirror, filer hardware, port, interface, cluster and disk health, but also NetApp alarms
# On Github:        https://github.com/OutsideIT/check_netapp_ontap
# On OutsideIT:     https://outsideit.net/monitoring-netapp-ontap/
# Copyright:
#   This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published
#   by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program is distributed
#   in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
#   PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General Public
#   License along with this program.  If not, see <http://www.gnu.org/licenses/>.

use warnings;
use strict;
use NaServer;
use NaElement;
use Getopt::Long;
use POSIX;

# do not show smartmatch warnings on older perl versions
no if $] >= 5.017011, warnings => 'experimental::smartmatch';

my $verbose = undef;
my $debug = undef;
my $trace = undef;
if ($verbose || $debug || $trace) {
	use Data::Dumper;
}

##############################################
## DISK HEALTH
##############################################

sub get_disk_info {
	my ($nahStorage, $strVHost) = @_;
	my $nahDiskIterator = NaElement->new("storage-disk-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahDiskInfo = NaElement->new("storage-disk-info");
	my $nahDiskOwnerInfo = NaElement->new("disk-ownership-info");
	my $strActiveTag = "";
	my %hshDiskInfo;

	if (defined($strVHost)) {
		$nahDiskIterator->child_add($nahQuery);
		$nahQuery->child_add($nahDiskInfo);
		$nahDiskInfo->child_add($nahDiskOwnerInfo);
		$nahDiskOwnerInfo->child_add_string("home-node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahDiskIterator->child_add_string("tag", $strActiveTag);
		}

		$nahDiskIterator->child_add_string("max-records", 600);
		my $nahResponse = $nahStorage->invoke_elem($nahDiskIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahDisk ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strDiskName = $nahDisk->child_get_string("disk-name");
			$hshDiskInfo{$strDiskName}{'home-node'} = $nahDisk->child_get("disk-ownership-info")->child_get_string("home-node-name");
			$hshDiskInfo{$strDiskName}{'current-node'} = $nahDisk->child_get("disk-ownership-info")->child_get_string("owner-node-name");
			if (defined($nahDisk->child_get("disk-raid-info")->child_get("disk-aggregate-info"))) {
				$hshDiskInfo{$strDiskName}{'scrubbing'} = $nahDisk->child_get("disk-raid-info")->child_get("disk-aggregate-info")->child_get_string("is-media-scrubbing");
				$hshDiskInfo{$strDiskName}{'offline'} = $nahDisk->child_get("disk-raid-info")->child_get("disk-aggregate-info")->child_get_string("is-offline");
				$hshDiskInfo{$strDiskName}{'prefailed'} = $nahDisk->child_get("disk-raid-info")->child_get("disk-aggregate-info")->child_get_string("is-prefailed");
				$hshDiskInfo{$strDiskName}{'reconstructing'} = $nahDisk->child_get("disk-raid-info")->child_get("disk-aggregate-info")->child_get_string("is-reconstructing");
			} else {
				$hshDiskInfo{$strDiskName}{'scrubbing'} = "false";
				$hshDiskInfo{$strDiskName}{'offline'} = "false";
				$hshDiskInfo{$strDiskName}{'prefailed'} = "false";
				$hshDiskInfo{$strDiskName}{'reconstructing'} = "false";
			}

			if ($nahDisk->child_get("disk-raid-info")->child_get("disk-outage-info")) {
				$hshDiskInfo{$strDiskName}{'outage'} = $nahDisk->child_get("disk-raid-info")->child_get("disk-outage-info")->child_get_string("reason");
			} else {
				$hshDiskInfo{$strDiskName}{'outage'} = "ok";
			}
		}
	}

	return \%hshDiskInfo;
}

sub calc_disk_health {
	my $hrefDiskInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	my @aryFDRWarning = ("bypassed", "label version", "labeled broken", "LUN resized", "missing", "predict failure", "rawsize shrank", "recovering", "sanitizing", "unassigned");
	my @aryFDRCritical = ("bad label", "failed", "init failed", "not responding", "unknown");

	foreach my $strDisk (keys %$hrefDiskInfo) {
		$intObjectCount = $intObjectCount + 1;
		if (defined($hrefDiskInfo->{$strDisk}->{'home-node'}) && defined($hrefDiskInfo->{$strDisk}->{'current-node'})) {
			if ($hrefDiskInfo->{$strDisk}->{'home-node'} ne $hrefDiskInfo->{$strDisk}->{'current-node'}) {
				my $strNewMessage = $strDisk . " is not on home node and is currently on " . $hrefDiskInfo->{$strDisk}->{'current-node'};
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 1);
			}
		}

		if (defined($hrefDiskInfo->{$strDisk}->{'scrubbing'}) && ($hrefDiskInfo->{$strDisk}->{'scrubbing'} eq "true")) {
			my $strNewMessage = $strDisk . " is scrubbing";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 0);
		}

		if (defined($hrefDiskInfo->{$strDisk}->{'offline'}) && ($hrefDiskInfo->{$strDisk}->{'offline'} eq "true")) {
			my $strNewMessage = $strDisk . " is offline";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		}

		if (defined($hrefDiskInfo->{$strDisk}->{'prefailed'}) && ($hrefDiskInfo->{$strDisk}->{'prefailed'} eq "true")) {
			my $strNewMessage = $strDisk . " is prefailed";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 1);
		}

		if (defined($hrefDiskInfo->{$strDisk}->{'reconstructing'}) && ($hrefDiskInfo->{$strDisk}->{'reconstructing'} eq "true")) {
			my $strNewMessage = $strDisk . " is reconstructing";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 1);
		}

		if ($hrefDiskInfo->{$strDisk}->{'outage'} ne "ok") {
			my $strNewMessage = $strDisk . " state is " . $hrefDiskInfo->{$strDisk}->{'outage'};
			$strOutput = get_nagios_description($strOutput, $strNewMessage);

			my $bStateSet = 0;
			foreach my $strEntry (@aryFDRWarning) {
				if ($hrefDiskInfo->{$strDisk}->{'outage'} eq $strEntry) {
					$intState = get_nagios_state($intState, 1);
					$bStateSet = 1;
					last;
				}
			}

			if (!$bStateSet) {
				foreach my $strEntry (@aryFDRCritical) {
					if ($hrefDiskInfo->{$strDisk}->{'outage'} eq $strEntry) {
						$intState = get_nagios_state($intState, 2);
					}
				}
			}
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## SPARE HEALTH
##############################################

sub get_spare_info {
	my ($nahStorage, $strVHost, $strWarning, $strCritical) = @_;
	my $nahSpareIterator = NaElement->new("storage-disk-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahSpareInfo = NaElement->new("storage-disk-info");
	my $nahSpareOwnerInfo = NaElement->new("disk-ownership-info");
	my $strActiveTag = "";
	my %hshSpareInfo;

	if (defined($strVHost)) {
		$nahSpareIterator->child_add($nahQuery);
		$nahQuery->child_add($nahSpareInfo);
		$nahSpareInfo->child_add($nahSpareOwnerInfo);
		$nahSpareOwnerInfo->child_add_string("home-node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahSpareIterator->child_add_string("tag", $strActiveTag);
		}

		$nahSpareIterator->child_add_string("max-records", 600);
		my $nahResponse = $nahStorage->invoke_elem($nahSpareIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		SPARE:
		foreach my $nahSpare ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strSpareName = $nahSpare->child_get_string("disk-name");

			my $raidInfo = $nahSpare->child_get("disk-raid-info");
			my $containertype = $raidInfo->child_get_string("container-type");

			if (!defined($containertype)) {
				next SPARE;
			} elsif ($containertype eq "spare" || $containertype eq "unassigned") {
				my $nodeName = $raidInfo->child_get_string("active-node-name");
				my $spareInfo = $raidInfo->child_get("disk-spare-info");
				my $zeroed = $spareInfo->child_get_string('is-zeroed');

				$hshSpareInfo{$nodeName}{$strSpareName}{'status'} = $containertype;
				$hshSpareInfo{$nodeName}{$strSpareName}{'zeroed'} = $zeroed;
			} else {
				next SPARE;
			}
		}
	}

	# Include ADP spares, which are only reported under aggregate spares (not in the spare container)
	$nahSpareIterator = NaElement->new("aggr-spare-get-iter");
	$nahQuery = NaElement->new("query");
	$nahSpareInfo = NaElement->new("storage-disk-info");
	$nahSpareOwnerInfo = NaElement->new("disk-ownership-info");
	$strActiveTag = "";

	if (defined($strVHost)) {
		$nahSpareIterator->child_add($nahQuery);
		$nahQuery->child_add($nahSpareInfo);
		$nahSpareInfo->child_add($nahSpareOwnerInfo);
		$nahSpareOwnerInfo->child_add_string("original-owner", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahSpareIterator->child_add_string("tag", $strActiveTag);
		}

		$nahSpareIterator->child_add_string("max-records", 600);
		my $nahResponse = $nahStorage->invoke_elem($nahSpareIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		SPARE:
		foreach my $nahSpare ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strSpareName = $nahSpare->child_get_string("disk");
			my $strUsableBlk = $nahSpare->child_get_string("local-usable-data-size-blks");

			# Skip root partition spares
			if (!defined($strUsableBlk)) {
				next SPARE;
			} else {
				my $nodeName = $nahSpare->child_get_string("original-owner");
				my $zeroed = $nahSpare->child_get_string('is-disk-zeroed');

				$hshSpareInfo{$nodeName}{$strSpareName}{'status'} = 'spare';
				$hshSpareInfo{$nodeName}{$strSpareName}{'zeroed'} = $zeroed;
			}
		}
	}

	return \%hshSpareInfo;
}

sub calc_spare_health {
	my ($hrefSpareInfo, $strVHost, $strWarning, $strCritical) = @_;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;
	my ($unknownStatus, $okStatus, $warnStatus, $critStatus) = (0, 0, 0, 0);

	NODE:
	foreach my $node (keys %$hrefSpareInfo) {
		if (defined($strVHost) and $node ne $strVHost) {
			next NODE;
		}

		my ($spareCount, $unassignedCount, $unknownCount, $notZeroedCount) = (0, 0, 0, 0);
		my $strNewMessage;

		foreach my $strSpare (keys %{$hrefSpareInfo->{$node}}) {
			$intObjectCount++;

			my $zeroedStatus = $hrefSpareInfo->{$node}->{$strSpare}->{'zeroed'};
			if (defined($zeroedStatus) and $zeroedStatus ne "true") {
				$notZeroedCount++;
			}
			my $status = $hrefSpareInfo->{$node}->{$strSpare}->{'status'};
			if (defined($status) and $status eq "spare") {
				$spareCount++;
			} elsif (defined($status) and $status eq "unassigned") {
				$unassignedCount++;
			} else {
				$unknownCount++;
			}
		}

		if ($spareCount < $strCritical) {
			$critStatus++;
		} elsif ($spareCount < $strWarning) {
			$warnStatus++;
		} elsif ($spareCount >= $strWarning) {
			$okStatus++;
		} else {
			$unknownStatus++;
		}

		$strNewMessage = sprintf("%s: %d spare disks (%s not zeroed) and %s unassigned", $node, $spareCount, $notZeroedCount, $unassignedCount);
		$strOutput = get_nagios_description($strOutput, $strNewMessage);
	}

	# No spare disk case
	if ($intObjectCount == 0) {
		if ($intObjectCount < $strCritical) {
			$critStatus++;
		} elsif ($intObjectCount < $strWarning) {
			$warnStatus++;
		} elsif ($intObjectCount >= $strWarning) {
			$okStatus++;
		} else {
			$unknownStatus++;
		}

		my $strNewMessage = sprintf("No spare disk found on nodes");
		$strOutput = get_nagios_description($strOutput, $strNewMessage);
	}

	# No output case
	if (!(defined($strOutput))) {
		$unknownStatus++;
		my $strNewMessage = sprintf("No output");
		$strOutput = get_nagios_description($strOutput, $strNewMessage);
	}

	if ($critStatus > 0) {
		$intState = get_nagios_state($intState, 2);
	} elsif ($warnStatus > 0) {
		$intState = get_nagios_state($intState, 1);
	} elsif ($okStatus > 0) {
		$intState = get_nagios_state($intState, 0);
	} else {
		$intState = get_nagios_state($intState, 3);
	}

	return $intState, $strOutput;
}

##############################################
## PORT HEALTH
##############################################

sub get_port_health {
	my ($nahStorage, $strVHost) = @_;
	my $nahPortIterator = NaElement->new("net-port-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahPortInfo = NaElement->new("net-port-info");
	my $strActiveTag = "";
	my %hshPortInfo;

	if (defined($strVHost)) {
		$nahPortIterator->child_add($nahQuery);
		$nahQuery->child_add($nahPortInfo);
		$nahPortInfo->child_add_string("node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahPortIterator->child_add_string("tag", $strActiveTag);
		}

		$nahPortIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahPortIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahPort ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strName = $nahPort->child_get_string("node") . "/" . $nahPort->child_get_string("port");
			if ($nahPort->child_get_string("is-administrative-up") eq "true") {
				$hshPortInfo{$strName}{'admin-status'} = "up";
			} else {
				$hshPortInfo{$strName}{'admin-status'} = "down";
			}

			$hshPortInfo{$strName}{'link-status'} = $nahPort->child_get_string("link-status");
		}
	}

	return \%hshPortInfo;
}

##############################################
## INTERFACE HEALTH
##############################################

sub get_interface_health {
	my ($nahStorage, $strVHost) = @_;
	my $nahIntIterator = NaElement->new("net-interface-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahIntInfo = NaElement->new("net-interface-info");
	my $strActiveTag = "";
	my %hshInterfaceInfo;

	if (defined($strVHost)) {
		$nahIntIterator->child_add($nahQuery);
		$nahQuery->child_add($nahIntInfo);
		$nahIntInfo->child_add_string("vserver", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahIntIterator->child_add_string("tag", $strActiveTag);
		}

		$nahIntIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahIntIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahInt ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strName = $nahInt->child_get_string("home-node") . "/" . $nahInt->child_get_string("vserver") . $nahInt->child_get_string("interface-name");
			$hshInterfaceInfo{$strName}{'admin-status'} = $nahInt->child_get_string("administrative-status");
			# operational-status seems not always be set
			if (defined $nahInt->child_get_string("operational-status")) {
				$hshInterfaceInfo{$strName}{'link-status'} = $nahInt->child_get_string("operational-status");
			} else {
				$hshInterfaceInfo{$strName}{'link-status'} = 'unknown';
			}
			$hshInterfaceInfo{$strName}{'home-node'} = $nahInt->child_get_string("home-node");
			$hshInterfaceInfo{$strName}{'current-node'} = $nahInt->child_get_string("current-node");
			$hshInterfaceInfo{$strName}{'home-port'} = $nahInt->child_get_string("home-port");
			$hshInterfaceInfo{$strName}{'current-port'} = $nahInt->child_get_string("current-port");
		}
	}

	return \%hshInterfaceInfo;
}

sub calc_interface_health {
	my ($hrefInterfaceInfo, $strWarning, $strCritical, $strSuboption, $strReport) = @_;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;
	my $strMultiline = '';
	my $intNbIncorrectStatus = 0;
	my $intNbIncorrectNode = 0;
	my $intNbIncorrectPort = 0;
	my ($strCheckLIFStatus, $strCheckLIFHomeNode, $strCheckLIFHomePort) = (1) x 3;
	if (defined $strSuboption) {
		$strCheckLIFStatus = $strCheckLIFHomeNode = $strCheckLIFHomePort = 0;
		my @arySuboption = split(",",$strSuboption);
		if ("status" ~~ @arySuboption) { $strCheckLIFStatus = 1; }
		if ("home-node" ~~ @arySuboption) { $strCheckLIFHomeNode = 1; }
		if ("home-port" ~~ @arySuboption) { $strCheckLIFHomePort = 1; }
	}

	foreach my $strInt (keys %$hrefInterfaceInfo) {
		$intObjectCount = $intObjectCount + 1;

		if ($strCheckLIFStatus) {
			if (!($hrefInterfaceInfo->{$strInt}->{'admin-status'} eq $hrefInterfaceInfo->{$strInt}->{'link-status'})) {
				my $strNewMessage = $strInt . " is " . $hrefInterfaceInfo->{$strInt}->{'link-status'} . " but admin status is " . $hrefInterfaceInfo->{$strInt}->{'admin-status'};
				$strOutput = get_nagios_description($strOutput, $strNewMessage);

				if ($hrefInterfaceInfo->{$strInt}->{'link-status'} eq "down") {
					$intState = get_nagios_state($intState, 2);
					$intNbIncorrectStatus = $intNbIncorrectStatus + 1;
				} elsif ($hrefInterfaceInfo->{$strInt}->{'link-status'} eq "up") {
					$intState = get_nagios_state($intState, 1);
				} elsif ($hrefInterfaceInfo->{$strInt}->{'link-status'} eq "unknown") {
					$intState = get_nagios_state($intState, 3);
				}
			}
		}

		if ($strCheckLIFHomeNode) {
			if (defined($hrefInterfaceInfo->{$strInt}->{'home-node'}) && defined($hrefInterfaceInfo->{$strInt}->{'current-node'})) {
				if (!($hrefInterfaceInfo->{$strInt}->{'home-node'} eq $hrefInterfaceInfo->{$strInt}->{'current-node'})) {
					my $strNewMessage = $strInt . " home is " . $hrefInterfaceInfo->{$strInt}->{'home-node'} . " but current node is " . $hrefInterfaceInfo->{$strInt}->{'current-node'};
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$strMultiline = get_nagios_multiline($strMultiline, $strNewMessage);
					$intState = get_nagios_state($intState, 1);
					$intNbIncorrectNode = $intNbIncorrectNode + 1;
				}
			}
		}

		if ($strCheckLIFHomePort) {
			if (defined($hrefInterfaceInfo->{$strInt}->{'home-port'}) && defined($hrefInterfaceInfo->{$strInt}->{'current-port'})) {
				if (!($hrefInterfaceInfo->{$strInt}->{'home-port'} eq $hrefInterfaceInfo->{$strInt}->{'current-port'})) {
					my $strNewMessage = $strInt . " home is " . $hrefInterfaceInfo->{$strInt}->{'home-port'} . " but current port is " . $hrefInterfaceInfo->{$strInt}->{'current-port'};
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$strMultiline = get_nagios_multiline($strMultiline, $strNewMessage);
					$intState = get_nagios_state($intState, 1);
					$intNbIncorrectPort = $intNbIncorrectPort + 1;
				}
			}
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked) ";
	} else {
		if(defined($strReport)) {
			if ($strReport eq "short" || $strReport eq "long") {
				$strOutput .= "\n$strMultiline";
			} elsif ($strReport eq "html") {
				my $strHTML = draw_html_table_interface_health($hrefInterfaceInfo, $strCheckLIFStatus, $strCheckLIFHomeNode, $strCheckLIFHomePort);
				$strOutput .= "\n$strHTML";
			}
		} else {
			$strOutput .= "\n"
		}
	}

	return $intState, $strOutput;
}

sub draw_html_table_interface_health {
	my ($hrefInfo, $strCheckLIFStatus, $strCheckLIFHomeNode, $strCheckLIFHomePort) = @_;
	my @headers = qw(LIF admin-status link-status home-node current-node home-port current-port);
	my @columns = qw(admin-status link-status home-node current-node home-port current-port);
	my $html_table="";
	$html_table .= "<table class=\"common-table\" style=\"border-collapse:collapse; border: 1px solid black;\">";
	$html_table .= "<tr>";
	foreach (@headers) {
		$html_table .= "<th style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$_."</th>";
	}
	$html_table .= "</tr>";
	foreach my $lif (sort {lc $a cmp lc $b} keys %$hrefInfo) {
#	foreach my $lif (keys %$hrefInfo) {
		$html_table .= "<tr>";
		$html_table .= "<tr style=\"border: 1px solid black;\">";
		$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #acacac;\">".$lif."</td>";
		foreach my $attr (@columns) {
			if ($strCheckLIFStatus && $attr eq "link-status") {
				if ($hrefInfo->{$lif}->{"admin-status"} eq "up" && $hrefInfo->{$lif}->{"link-status"} eq "down"){
					$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$lif}->{$attr}."</td>";
				} else {
					$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$lif}->{$attr}."</td>";
				}
			} elsif ($strCheckLIFHomeNode && $attr eq "current-node") {
				if (defined($hrefInfo->{$lif}->{'home-node'}) && defined($hrefInfo->{$lif}->{'current-node'})) {
					if (!($hrefInfo->{$lif}->{'home-node'} eq $hrefInfo->{$lif}->{'current-node'})) {
						$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$lif}->{$attr}."</td>";
					} else {
						$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$lif}->{$attr}."</td>";
					}
				}
			} elsif ($strCheckLIFHomePort && $attr eq "current-port") {
				if (defined($hrefInfo->{$lif}->{'home-port'}) && defined($hrefInfo->{$lif}->{'current-port'})) {
					if (!($hrefInfo->{$lif}->{'home-port'} eq $hrefInfo->{$lif}->{'current-port'})) {
						$html_table .= "<td class=\"state-critical\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #f83838\">".$hrefInfo->{$lif}->{$attr}."</td>";
					} else {
						$html_table .= "<td class=\"state-ok\" style=\"text-align: left; padding-left: 4px; padding-right: 6px; background-color: #33ff00\">".$hrefInfo->{$lif}->{$attr}."</td>";
					}
				}
			} else {
				if (defined $hrefInfo->{$lif}->{$attr}) {
					$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\">".$hrefInfo->{$lif}->{$attr}."</td>";
				} else {
					$html_table .= "<td style=\"text-align: left; padding-left: 4px; padding-right: 6px;\"></td>";
				}
			}
		}
		$html_table .= "</tr>";
	}
	$html_table .= "</table>\n";

	return $html_table;
}

##############################################
## CLUSTER NODE HEALTH
##############################################

sub get_cluster_node_health {
	my ($nahStorage, $strVHost) = @_;
	my $nahClusterNodeIterator = NaElement->new("cluster-node-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahClusterNodeInfo = NaElement->new("cluster-node-info");
	my $strActiveTag = "";
	my %hshClusterNodeInfo;

	if (defined($strVHost)) {
		$nahClusterNodeIterator->child_add($nahQuery);
		$nahQuery->child_add($nahClusterNodeInfo);
		$nahClusterNodeInfo->child_add_string("originating-node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahClusterNodeIterator->child_add_string("tag", $strActiveTag);
		}

		$nahClusterNodeIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahClusterNodeIterator);
		validate_ontapi_response($nahResponse, "Failed node health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahNode ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strName = $nahNode->child_get_string("node-name");
			$hshClusterNodeInfo{$strName}{'clusternode-healthy'} = $nahNode->child_get_string("is-node-healthy");
		}
	}

	return \%hshClusterNodeInfo;
}

sub calc_cluster_node_health {
	my $hrefClusterNodeInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	foreach my $strNode (keys %$hrefClusterNodeInfo) {
		$intObjectCount = $intObjectCount + 1;
		if ($hrefClusterNodeInfo->{$strNode}->{'clusternode-healthy'} eq "false") {
			my $strNewMessage = $strNode . " clusternode is unhealthy";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## CLUSTER HEALTH
##############################################

sub get_cluster_health {
	my ($nahStorage, $strVHost) = @_;
	my $nahClusterIterator = NaElement->new("cluster-peer-health-info-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahClusterInfo = NaElement->new("cluster-peer-health-info");
	my $strActiveTag = "";
	my %hshClusterInfo;

	if (defined($strVHost)) {
		$nahClusterIterator->child_add($nahQuery);
		$nahQuery->child_add($nahClusterInfo);
		$nahClusterInfo->child_add_string("originating-node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahClusterIterator->child_add_string("tag", $strActiveTag);
		}

		$nahClusterIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahClusterIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahNode ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strName = $nahNode->child_get_string("originating-node");
			$hshClusterInfo{$strName}{'destination'} = $nahNode->child_get_string("destination-node");
			$hshClusterInfo{$strName}{'cluster-healthy'} = $nahNode->child_get_string("is-cluster-healthy");
			$hshClusterInfo{$strName}{'destination-available'} = $nahNode->child_get_string("is-destination-node-available");
			$hshClusterInfo{$strName}{'in-quorum'} = $nahNode->child_get_string("is-node-healthy");
		}
	}

	return \%hshClusterInfo;
}

sub calc_cluster_health {
	my $hrefClusterInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	foreach my $strNode (keys %$hrefClusterInfo) {
		$intObjectCount = $intObjectCount + 1;
		if ($hrefClusterInfo->{$strNode}->{'destination-available'} eq "false") {
			my $strNewMessage = $strNode . "->" . $hrefClusterInfo->{$strNode}->{'destination'} . " destination node is unavailable";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		} elsif ($hrefClusterInfo->{$strNode}->{'in-quorum'} eq "false") {
			my $strNewMessage = $strNode . "->" . $hrefClusterInfo->{$strNode}->{'destination'} . " originating node is not in quorum";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		} elsif ($hrefClusterInfo->{$strNode}->{'cluster-healthy'} eq "false") {
			my $strNewMessage = $strNode . "->" . $hrefClusterInfo->{$strNode}->{'destination'} . " cluster peer relationship is unhealthy";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## VSCAN HEALTH
##############################################

sub get_vscan_info {
	my ($nahVscan, $strVHost) = @_;
	my $nahVscanIterator = NaElement->new("vscan-status-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahVscanInfo = NaElement->new("vscan-status-info");
	my $strActiveTag = "";
	my %hshVscanInfo;

	if (defined($strVHost)) {
		$nahVscanIterator->child_add($nahQuery);
		$nahQuery->child_add($nahVscanInfo);
		$nahVscanInfo->child_add_string("vserver", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahVscanIterator->child_add_string("tag", $strActiveTag);
		}

		$nahVscanIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahVscan->invoke_elem($nahVscanIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahNode ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strName = $nahNode->child_get_string("vserver");
			$hshVscanInfo{$strName}{'is-vscan-enabled'} = $nahNode->child_get_string("is-vscan-enabled");
		}
	}

	return \%hshVscanInfo;
}

sub calc_vscan_health {
	my $hrefVscanInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	foreach my $strNode (keys %$hrefVscanInfo) {
		$intObjectCount = $intObjectCount + 1;
		if ($hrefVscanInfo->{$strNode}->{'is-vscan-enabled'} eq "false") {
			my $strNewMessage = "vscan is disabled on $strNode";
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## NETAPP ALARMS
##############################################

sub get_netapp_alarms {
	my ($nahStorage, $strVHost) = @_;
	my $nahAlarmIterator = NaElement->new("dashboard-alarm-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahDashInfo = NaElement->new("dashboard-alarm-info");
	my $strActiveTag = "";
	my %hshAlarms;

	if (defined($strVHost)) {
		$nahAlarmIterator->child_add($nahQuery);
		$nahQuery->child_add($nahDashInfo);
		$nahDashInfo->child_add_string("node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahAlarmIterator->child_add_string("tag", $strActiveTag);
		}

		$nahAlarmIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahAlarmIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahAlarm ($nahResponse->child_get("attributes-list")->children_get()) {
			# ignore alarms of type "aggregate_used" because of fixed percentages
			next if ($nahAlarm->child_get_string("dashboard-metric-type") eq "aggregate_used" );

			# ignore cifs/op_latency due to a netapp calculation bug
			next if ($nahAlarm->child_get_string("object-name")."/".$nahAlarm->child_get_string("dashboard-metric-type") eq "cifs/op_latency");

			my $strName = $nahAlarm->child_get_string("node") . "/" . $nahAlarm->child_get_string("object-name") . "/" . $nahAlarm->child_get_string("dashboard-metric-type");
			$hshAlarms{$strName}{'value'} = $nahAlarm->child_get_string("last-value");
			$hshAlarms{$strName}{'state'} = $nahAlarm->child_get_string("state");
		}
	}

	$nahAlarmIterator = NaElement->new("diagnosis-alert-get-iter");
	$strActiveTag = "";

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahAlarmIterator->child_add_string("tag", $strActiveTag);
		}

		$nahAlarmIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahAlarmIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahAlarm ($nahResponse->child_get("attributes-list")->children_get()) {
			if (!($nahAlarm->child_get_string("acknowledge") eq "true" || $nahAlarm->child_get_string("suppress") eq "true")) {
				my $strName = $nahAlarm->child_get_string("node") . "/" . $nahAlarm->child_get_string("alerting-resource-name") . "/" . $nahAlarm->child_get_string("subsystem");
				$hshAlarms{$strName}{'value'} = $nahAlarm->child_get_string("probable-cause-description");
				$hshAlarms{$strName}{'state'} = $nahAlarm->child_get_string("perceived-severity");
			}
		}
	}

	return \%hshAlarms;
}

sub calc_netapp_alarm_health {
	my $hrefAlarmsInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	foreach my $strAlarm (keys %$hrefAlarmsInfo) {
		$intObjectCount = $intObjectCount + 1;
		if ($hrefAlarmsInfo->{$strAlarm}->{'state'} eq "critical") {
			my $strNewMessage = $strAlarm . " " . $hrefAlarmsInfo->{$strAlarm}->{'value'};
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 2);
		} elsif ($hrefAlarmsInfo->{$strAlarm}->{'state'} ne "ok") {
			my $strNewMessage = $strAlarm . " " . $hrefAlarmsInfo->{$strAlarm}->{'value'};
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 1);
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## FILER HEALTH
##############################################

sub get_filer_hardware {
	my ($nahStorage, $strVHost) = @_;
	my $nahFilerIterator = NaElement->new("system-node-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahNodeInfo = NaElement->new("node-details-info");
	my $strActiveTag = "";
	my %hshFilerHardware;

	if (defined($strVHost)) {
		$nahFilerIterator->child_add($nahQuery);
		$nahQuery->child_add($nahNodeInfo);
		$nahNodeInfo->child_add_string("node", $strVHost);
	}

	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahFilerIterator->child_add_string("tag", $strActiveTag);
		}

		$nahFilerIterator->child_add_string("max-records", 100);
		my $nahResponse = $nahStorage->invoke_elem($nahFilerIterator);
		validate_ontapi_response($nahResponse, "Failed filer health query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		foreach my $nahFilerObj ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strNodeName = $nahFilerObj->child_get_string("node");
			# sometimes no enviroment info is present in server response
			if (defined $nahFilerObj->child_get_string("env-failed-fan-count")) {
				$hshFilerHardware{$strNodeName . "/fan"}{'object'} = "fan";
				$hshFilerHardware{$strNodeName . "/fan"}{'count'} = $nahFilerObj->child_get_string("env-failed-fan-count");
				$hshFilerHardware{$strNodeName . "/fan"}{'message'} = $nahFilerObj->child_get_string("env-failed-fan-message");
			}

			# sometimes no enviroment info is present in server response
			if (defined $nahFilerObj->child_get_string("env-failed-power-supply-count")) {
				$hshFilerHardware{$strNodeName . "/psu"}{'object'} = "psu";
				$hshFilerHardware{$strNodeName . "/psu"}{'count'} = $nahFilerObj->child_get_string("env-failed-power-supply-count");
				$hshFilerHardware{$strNodeName . "/psu"}{'message'} = $nahFilerObj->child_get_string("env-failed-power-supply-message");
			}

			# sometimes no enviroment info is present in server response
			if (defined $nahFilerObj->child_get_string("env-over-temperature")) {
				$hshFilerHardware{$strNodeName . "/temp"}{'object'} = "temp";
				$hshFilerHardware{$strNodeName . "/temp"}{'count'} = $nahFilerObj->child_get_string("env-over-temperature");
			}

			# sometimes no enviroment info is present in server response
			if (defined $nahFilerObj->child_get_string("nvram-battery-status")) {
				$hshFilerHardware{$strNodeName . "/battery"}{'object'} = "battery";
				$hshFilerHardware{$strNodeName . "/battery"}{'message'} = $nahFilerObj->child_get_string("nvram-battery-status");
			}
		}
	}

	return \%hshFilerHardware;
}

sub calc_filer_hardware_health {
	my ($hrefFilerInfo, $strWarning, $strCritical) = @_;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;
	my (@aryWarning, @aryCritical);

	if (defined($strWarning)) {
		@aryWarning = split(",", $strWarning);
	}

	if (defined($strCritical)) {
		@aryCritical = split(",", $strCritical);
	}

	foreach my $strFilerEntry (keys %$hrefFilerInfo) {
		$intObjectCount = $intObjectCount + 1;
		if ($hrefFilerInfo->{$strFilerEntry}{'object'} eq "fan") {
			if ($hrefFilerInfo->{$strFilerEntry}{'count'} > 0) {
				my $intStateSet = 2;
				foreach my $strWarnThresh (@aryWarning) {
					if ($strWarnThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 1;
					}
				}

				foreach my $strCritThresh (@aryCritical) {
					if ($strCritThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 2;
					}
				}

				if ($intStateSet > 0) {
					my $strNewMessage = $strFilerEntry . " has " . $hrefFilerInfo->{$strFilerEntry}{'count'} . " failed fans";
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, $intStateSet);
				}
			}
		} elsif ($hrefFilerInfo->{$strFilerEntry}{'object'} eq "psu") {
			if ($hrefFilerInfo->{$strFilerEntry}{'count'} > 0) {
				my $intStateSet = 2;
				foreach my $strWarnThresh (@aryWarning) {
					if ($strWarnThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 1;
					}
				}

				foreach my $strCritThresh (@aryCritical) {
					if ($strCritThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 2;
					}
				}

				if ($intStateSet > 0) {
					my $strNewMessage = $strFilerEntry . " has " . $hrefFilerInfo->{$strFilerEntry}{'count'} . " failed power supplies";
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, $intStateSet);
				}
			}
		} elsif ($hrefFilerInfo->{$strFilerEntry}{'object'} eq "temp") {
			if ($hrefFilerInfo->{$strFilerEntry}{'count'} eq "true") {
				my $intStateSet = 1;
				foreach my $strWarnThresh (@aryWarning) {
					if ($strWarnThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 1;
					}
				}

				foreach my $strCritThresh (@aryCritical) {
					if ($strCritThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 2;
					}
				}

				if ($intStateSet > 0) {
					my $strNewMessage = $strFilerEntry . " has breached the filer temperature warning threshold";
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, $intStateSet);
				}
			}
		} elsif ($hrefFilerInfo->{$strFilerEntry}{'object'} eq "battery") {
			if (!($hrefFilerInfo->{$strFilerEntry}{'message'} eq "battery_ok" || $hrefFilerInfo->{$strFilerEntry}{'message'} eq "battery_fully_charged")) {
				my $intStateSet = 1;
				foreach my $strWarnThresh (@aryWarning) {
					if ($strWarnThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 1;
					}
				}

				foreach my $strCritThresh (@aryCritical) {
					if ($strCritThresh eq $hrefFilerInfo->{$strFilerEntry}{'object'}) {
						$intStateSet = 2;
					}
				}

				if ($intStateSet > 0) {
					my $strNewMessage = $strFilerEntry . " is currently in state " . $hrefFilerInfo->{$strFilerEntry}{'message'};
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, $intStateSet);
				}
			}
		}
	}

	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## SNAPMIRROR HEALTH
##############################################

sub get_snapmirror_lag {
	# Get snapmirror monitoring objects
	my ($nahStorage, $strVHost) = @_;
	# Set up variables to handle the API queries for snapmirror retrieval.
	my $nahSMIterator = NaElement->new("snapmirror-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahSMInfo = NaElement->new("snapmirror-info");
	my $nahTag = NaElement->new("tag");
	my $strActiveTag = "";
	my %hshSMHealth;

	# Narrow search to only the requested node if configured by user with the -n option
	if (defined($strVHost)) {
		$nahSMIterator->child_add($nahQuery);
		$nahQuery->child_add($nahSMInfo);
		$nahSMInfo->child_add_string("destination-volume-node", $strVHost);
	}

	# The active tag is a feature of the NetApp API that allows you to do queries in batches. In this case we are getting records in batches of 100.
	$nahSMIterator->child_add_string("max-records", 100);
	$nahSMIterator->child_add($nahTag);
	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahTag->set_content($strActiveTag);
		}

		# Invoke the request.
		my $nahResponse = $nahStorage->invoke_elem($nahSMIterator);
		validate_ontapi_response($nahResponse, "Failed volume query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		# Stop if there are no more records.
		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		# Assign all the retrieved information to a hash.
		foreach my $nahSM ($nahResponse->child_get("attributes-list")->children_get()) {
			# Without snapmirror control plane v2 insufficient information is available to perform monitoring.
			if (defined($nahSM->child_get_string("relationship-control-plane")) && $nahSM->child_get_string("relationship-control-plane") eq "v2") {
				my $strSMName = $nahSM->child_get_string("destination-volume-node") . "://" . $nahSM->child_get_string("destination-location");
				$hshSMHealth{$strSMName}{'source'} = $nahSM->child_get_string("source-location");

				# Values may not necessarily exist so assign them if they do.
				if ($nahSM->child_get_string("is-healthy") eq "false") {
					$hshSMHealth{$strSMName}{'health'} = $nahSM->child_get_string("unhealthy-reason");
				}

				if ($nahSM->child_get_string("lag-time")) {
					$hshSMHealth{$strSMName}{'lag'} = $nahSM->child_get_string("lag-time");
				}
			}
		}
	}

	return \%hshSMHealth;
}

sub calc_snapmirror_health {
	# Work out which values have crossed the snapmirror thresholds defined by the user.
	my ($hrefSMInfo, $strWarning, $strCritical) = @_;
	my ($hrefWarnThresholds, $hrefCritThresholds) = snapmirror_threshold_converter($strWarning, $strCritical);
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	foreach my $strSM (keys %$hrefSMInfo) {
		$intObjectCount = $intObjectCount + 1;
		if (defined($hrefSMInfo->{$strSM}->{'health'})) {
			my $strNewMessage = $hrefSMInfo->{$strSM}->{'source'} . " -> " . $strSM . " is unhealthy: " . $hrefSMInfo->{$strSM}->{'health'};
			$strOutput = get_nagios_description($strOutput, $strNewMessage);
			$intState = get_nagios_state($intState, 1);
		}

		my $bProcess = 1;
		if (defined($hrefCritThresholds->{'lag-time'}) && defined($hrefSMInfo->{$strSM}->{'lag'})) {
			if ($hrefSMInfo->{$strSM}->{'lag'} > $hrefCritThresholds->{'lag-time'}) {
				my $strFriendlyTime = seconds_to_time($hrefSMInfo->{$strSM}->{'lag'});
				my $strNewMessage = $hrefSMInfo->{$strSM}->{'source'} . " -> " . $strSM . " lag time has reached " . $strFriendlyTime;
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 2);
				$bProcess = 0;
			}
		}

		if (defined($hrefWarnThresholds->{'lag-time'}) && defined($hrefSMInfo->{$strSM}->{'lag'}) && $bProcess) {
			if ($hrefSMInfo->{$strSM}->{'lag'} > $hrefWarnThresholds->{'lag-time'}) {
				my $strFriendlyTime = seconds_to_time($hrefSMInfo->{$strSM}->{'lag'});
				my $strNewMessage = $hrefSMInfo->{$strSM}->{'source'} . " -> " . $strSM . " lag time has reached " . $strFriendlyTime;
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 1);
			}
		}
	}

	# If everything looks ok and no output has been defined then set the message to display OK.
	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

sub snapmirror_threshold_converter {
	# Split the user input into a hash that's easy to compare with the values retrieved from the filers.
	my ($strWarning, $strCritical) = @_;
	my (%hshWarnThresholds, %hshCritThresholds, @aryWarning, @aryCritical, @aryStringsTemp);

	if (defined($strWarning)) {
		@aryWarning = split(",", $strWarning);
	}

	if (defined($strCritical)) {
		@aryCritical = split(",", $strCritical);
	}

	foreach my $strWarnThresh (@aryWarning) {
		if ($strWarnThresh =~ m/^[0-9]*[smhd]$/) {
			$hshWarnThresholds{'lag-time'} = time_to_seconds($strWarnThresh);
		} elsif ($strWarnThresh =~ m/^[a-zA-Z]*$/) {
			push(@aryStringsTemp, $strWarnThresh);
		}
	}

	$hshWarnThresholds{'strings'} = [@aryStringsTemp];
	undef(@aryStringsTemp);

	foreach my $strCritThresh (@aryCritical) {
		if ($strCritThresh =~ m/^[0-9]*[smhd]$/) {
			$hshCritThresholds{'lag-time'} = time_to_seconds($strCritThresh);
		} elsif ($strCritThresh =~ m/^[a-zA-Z]*$/) {
			push(@aryStringsTemp, $strCritThresh);
		}
	}

	$hshCritThresholds{'strings'} = [@aryStringsTemp];
	return \%hshWarnThresholds, \%hshCritThresholds;
}

##############################################
## QUOTA SPACE
##############################################

sub get_quota_space {
	# Get quota monitoring objects
	my ($nahStorage, $strVHost) = @_;
	# Set up variables to handle the API queries for quota retrieval.
	my $nahQuotaIterator = NaElement->new("quota-report-iter");
	my $nahQuery = NaElement->new("query");
	my $nahQuotaInfo = NaElement->new("quota");
	my $strActiveTag = "";
	my %hshQuotaUsage;

	# Narrow search to only the requested node if configured by user with the -n option
	if (defined($strVHost)) {
		$nahQuotaIterator->child_add($nahQuery);
		$nahQuery->child_add($nahQuotaInfo);
		$nahQuotaInfo->child_add_string("vserver", $strVHost);
	}

	# The active tag is a feature of the NetApp API that allows you to do queries in batches. In this case we are getting records in batches of 100.
	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahQuotaIterator->child_add_string("tag", $strActiveTag);
		}

		$nahQuotaIterator->child_add_string("max-records", 200);

		# Invoke the request.
		my $nahResponse = $nahStorage->invoke_elem($nahQuotaIterator);
		validate_ontapi_response($nahResponse, "Failed volume query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		# Stop if there are no more records.
		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		# Assign all the retrieved information to a hash.
		foreach my $nahQuota ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strQuotaName = $nahQuota->child_get_string("vserver") . "/" . $nahQuota->child_get_string("volume");

			# Alter name to include the tree path if the object has a tree path.
			if ($nahQuota->child_get_string("tree") ne "") {
				$strQuotaName = $strQuotaName . "/" . $nahQuota->child_get_string("tree");
			}

			$hshQuotaUsage{$strQuotaName}{'sub'} = "get_quota_space";
			$hshQuotaUsage{$strQuotaName}{'space-hard-limit'} = $nahQuota->child_get_string("disk-limit");
			$hshQuotaUsage{$strQuotaName}{'space-threshold'} = $nahQuota->child_get_string("threshold");
			$hshQuotaUsage{$strQuotaName}{'space-soft-limit'} = $nahQuota->child_get_string("soft-disk-limit");
			$hshQuotaUsage{$strQuotaName}{'space-used'} = $nahQuota->child_get_string("disk-used");
			$hshQuotaUsage{$strQuotaName}{'files-hard-limit'} = $nahQuota->child_get_string("file-limit");
			$hshQuotaUsage{$strQuotaName}{'files-soft-limit'} = $nahQuota->child_get_string("soft-file-limit");
			$hshQuotaUsage{$strQuotaName}{'files-used'} = $nahQuota->child_get_string("files-used");

		}
	}
	return \%hshQuotaUsage;
}

sub calc_quota_health {
	# Work out which values have crossed the quota thresholds defined on the filer.
	my $hrefQuotaInfo = shift;
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;

	# Iterate through each of the objects and test the values, then set the Nagios state information as necessary.
	foreach my $strQuota (keys %$hrefQuotaInfo) {
		$intObjectCount = $intObjectCount + 1;
		#my $intUsedToBytes = space_to_bytes($hrefQuotaInfo->{$strQuota}->{'space-used'});
		my $intUsedToBytes = $hrefQuotaInfo->{$strQuota}->{'space-used'}*1024;
		my $strReadableUsed = space_to_human_readable($intUsedToBytes);

		if ($hrefQuotaInfo->{$strQuota}->{'space-hard-limit'} ne "-") {
			if ($hrefQuotaInfo->{$strQuota}->{'space-used'} >= $hrefQuotaInfo->{$strQuota}->{'space-hard-limit'}) {
				# my $intThreshToBytes = space_to_bytes($hrefQuotaInfo->{$strQuota}->{'space-hard-limit'});
				my $intThreshToBytes = $hrefQuotaInfo->{$strQuota}->{'space-hard-limit'}*1024;
		my $strReadableThresh = space_to_human_readable($intThreshToBytes);
				my $strNewMessage = $strQuota . " - " . $strReadableUsed . "/" . $strReadableThresh . " SPACE USED";
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
		$intState = get_nagios_state($intState, 2);
			}
		} elsif ($hrefQuotaInfo->{$strQuota}->{'space-threshold'} ne "-") {
			if ($hrefQuotaInfo->{$strQuota}->{'space-used'} >= $hrefQuotaInfo->{$strQuota}->{'space-threshold'}) {
				# my $intThreshToBytes = space_to_bytes($hrefQuotaInfo->{$strQuota}->{'space-threshold'});
				my $intThreshToBytes = $hrefQuotaInfo->{$strQuota}->{'space-threshold'}*1024;
		my $strReadableThresh = space_to_human_readable($intThreshToBytes);
				my $strNewMessage = $strQuota . " - " . $strReadableUsed . "/" . $strReadableThresh . " SPACE USED";
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
		$intState = get_nagios_state($intState, 2);
			}
		} elsif ($hrefQuotaInfo->{$strQuota}->{'space-soft-limit'} ne "-") {
			if ($hrefQuotaInfo->{$strQuota}->{'space-used'} >= $hrefQuotaInfo->{$strQuota}->{'space-soft-limit'}) {
				# my $intThreshToBytes = space_to_bytes($hrefQuotaInfo->{$strQuota}->{'space-soft-limit'});
				my $intThreshToBytes = $hrefQuotaInfo->{$strQuota}->{'space-soft-limit'}*1024;
		my $strReadableThresh = space_to_human_readable($intThreshToBytes);
				my $strNewMessage = $strQuota . " - " . $strReadableUsed . "/" . $strReadableThresh . " SPACE USED";
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 1);
			}
		}

		if ($hrefQuotaInfo->{$strQuota}->{'files-hard-limit'} ne "-") {
			if ($hrefQuotaInfo->{$strQuota}->{'files-used'} >= $hrefQuotaInfo->{$strQuota}->{'files-hard-limit'}) {
				my $strNewMessage = $strQuota . " - " . $hrefQuotaInfo->{$strQuota}->{'files-used'} . "/" . $hrefQuotaInfo->{$strQuota}->{'files-hard-limit'} . " FILES USED";
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 2);
			}
		} elsif ($hrefQuotaInfo->{$strQuota}->{'files-soft-limit'} ne "-") {
			if ($hrefQuotaInfo->{$strQuota}->{'files-used'} >= $hrefQuotaInfo->{$strQuota}->{'files-soft-limit'}) {
				my $strNewMessage = $strQuota . " - " . $hrefQuotaInfo->{$strQuota}->{'files-used'} . "/" . $hrefQuotaInfo->{$strQuota}->{'files-soft-limit'} . " FILES USED";
				$strOutput = get_nagios_description($strOutput, $strNewMessage);
				$intState = get_nagios_state($intState, 1);
			}
		}

	}

	# If everything looks ok and no output has been defined then set the message to display OK.
	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	return $intState, $strOutput;
}

##############################################
## AGGREGATE SPACE
##############################################

sub get_aggregate_space {
	# Get aggregate monitoring objects
	my ($nahStorage, $strVHost) = @_;
	# Set up variables to handle the API queries for aggregate retrieval.
	my $nahAggIterator = NaElement->new("aggr-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahAggInfo = NaElement->new("aggr-attributes");
	my $nahAggIdInfo = NaElement->new("aggr-ownership-attributes");
	my $strActiveTag = "";
	my %hshAggUsage;

	# Narrow search to only the requested node if configured by user with the -n option
	if (defined($strVHost)) {
		$nahAggIterator->child_add($nahQuery);
		$nahQuery->child_add($nahAggInfo);
		$nahAggInfo->child_add($nahAggIdInfo);
		$nahAggIdInfo->child_add_string("home-name", $strVHost);
	}

	# The active tag is a feature of the NetApp API that allows you to do queries in batches. In this case we are getting records in batches of 100.
	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahAggIterator->child_add_string("tag", $strActiveTag);
		}

		$nahAggIterator->child_add_string("max-records", 100);

		# Invoke the request.
		my $nahResponse = $nahStorage->invoke_elem($nahAggIterator);
		validate_ontapi_response($nahResponse, "Failed volume query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		# Stop if there are no more records.
		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		# Assign all the retrieved information to a hash.
		foreach my $nahAgg ($nahResponse->child_get("attributes-list")->children_get()) {
			my $strAggName = $nahAgg->child_get_string("aggregate-name");
			my $strAggOwner = $nahAgg->child_get("aggr-ownership-attributes")->child_get_string("home-name");
			$strAggName = $strAggOwner . "/" . $strAggName;

			$hshAggUsage{$strAggName}{'sub'} = "get_aggregate_space";
			if ($nahAgg->child_get("aggr-raid-attributes")->child_get_string("state") ne "online") {
				$hshAggUsage{$strAggName}{'state'} = $nahAgg->child_get("aggr-raid-attributes")->child_get_string("state");
			} else {
				$hshAggUsage{$strAggName}{'state'} = $nahAgg->child_get("aggr-raid-attributes")->child_get_string("state");
				$hshAggUsage{$strAggName}{'space-total'} = $nahAgg->child_get("aggr-space-attributes")->child_get_string("size-total");
				if ($debug) {
					if ( $hshAggUsage{$strAggName}{'space-total'} == 0 || $hshAggUsage{$strAggName}{'space-total'} eq '0' ) {
						print "Aggregate $strAggName reports size-total of 0\n";
						print Dumper($nahAgg);
					}
				}
				$hshAggUsage{$strAggName}{'space-used'} = $nahAgg->child_get("aggr-space-attributes")->child_get_string("size-used");
				$hshAggUsage{$strAggName}{'inodes-total'} = $nahAgg->child_get("aggr-inode-attributes")->child_get_string("files-total");
				$hshAggUsage{$strAggName}{'inodes-used'} = $nahAgg->child_get("aggr-inode-attributes")->child_get_string("files-used");
				$hshAggUsage{$strAggName}{'home-owner'} = $nahAgg->child_get("aggr-ownership-attributes")->child_get_string("home-name");
				$hshAggUsage{$strAggName}{'current-owner'} = $nahAgg->child_get("aggr-ownership-attributes")->child_get_string("owner-name");
			}
		}
	}

	return \%hshAggUsage;
}

##############################################
## SNAPSHOT SPACE
##############################################

sub get_snap_space {
	# Get snapshot monitoring objects
	my ($nahStorage, $strVHost) = @_;
	# Set up variables to handle the API queries for snapshot retrieval.
	my $nahVolIterator = NaElement->new("volume-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahVolInfo = NaElement->new("volume-attributes");
	my $nahVolIdInfo = NaElement->new("volume-id-attributes");
	my $nahTag = NaElement->new("tag");
	my $strActiveTag = "";
	my %hshVolUsage;

	# Narrow search to only the requested node if configured by user with the -n option
	if (defined($strVHost)) {
		$nahVolIterator->child_add($nahQuery);
		$nahQuery->child_add($nahVolInfo);
		$nahVolInfo->child_add($nahVolIdInfo);
		$nahVolIdInfo->child_add_string("owning-vserver-name", $strVHost);
	}

	# The active tag is a feature of the NetApp API that allows you to do queries in batches. In this case we are getting records in batches of 100.
	$nahVolIterator->child_add_string("max-records", 100);
	$nahVolIterator->child_add($nahTag);
	while(defined($strActiveTag)) {
		if ($strActiveTag ne "") {
			$nahTag->set_content($strActiveTag);
		}

		# Invoke the request.
		my $nahResponse = $nahStorage->invoke_elem($nahVolIterator);
		validate_ontapi_response($nahResponse, "Failed volume query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");

		# Stop if there are no more records.
		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		# Assign all the retrieved information to a hash.
		foreach my $nahVol ($nahResponse->child_get("attributes-list")->children_get()) {

			my $strVolName = $nahVol->child_get("volume-id-attributes")->child_get_string("name");
			my $strVolOwner = $nahVol->child_get("volume-id-attributes")->child_get_string("owning-vserver-name");
			$strVolName = $strVolOwner . "/" . $strVolName;

			# Don't monitor a volume that is currently being moved as it will result in errors.
			if (defined($nahVol->child_get("volume-state-attributes")->child_get_string("is-moving")) &&
				$nahVol->child_get("volume-state-attributes")->child_get_string("is-moving") eq "true") {
				next;
			}

			# Don't check snapshots of volumes with type TMP (7-Mode Transition Tool)
			if ($nahVol->child_get("volume-id-attributes")->child_get_string("type") eq "tmp") {
				next;
			}

			$hshVolUsage{$strVolName}{'sub'} = "get_snap_space";
			if ($nahVol->child_get("volume-state-attributes")->child_get_string("state") ne "online") {
				$hshVolUsage{$strVolName}{'state'} = $nahVol->child_get("volume-state-attributes")->child_get_string("state");
			} else {
				$hshVolUsage{$strVolName}{'state'} = $nahVol->child_get("volume-state-attributes")->child_get_string("state");
				$hshVolUsage{$strVolName}{'space-total'} = $nahVol->child_get("volume-space-attributes")->child_get_string("snapshot-reserve-size");
				if ($debug) {
					if ( $hshVolUsage{$strVolName}{'space-total'} == 0 || $hshVolUsage{$strVolName}{'space-total'} eq '0' ) {
						print "Snapshot $strVolName reports size-total of 0\n";
						print Dumper($nahVol);
					}
				}
				$hshVolUsage{$strVolName}{'space-used'} = $nahVol->child_get("volume-space-attributes")->child_get_string("size-used-by-snapshots");
				$hshVolUsage{$strVolName}{'inodes-total'} = $nahVol->child_get("volume-inode-attributes")->child_get_string("files-total");
				$hshVolUsage{$strVolName}{'inodes-used'} = $nahVol->child_get("volume-inode-attributes")->child_get_string("files-used");
			}
		}
	}

	return \%hshVolUsage;
}

##############################################
## VOLUME SPACE
##############################################

sub get_volume_space {
	# Get volume monitoring objects
	my ($nahStorage, $strVHost) = @_;
	# Set up variables to handle the API queries for volume retrieval.
	my $nahVolIterator = NaElement->new("volume-get-iter");
	my $nahQuery = NaElement->new("query");
	my $nahVolInfo = NaElement->new("volume-attributes");
	my $nahVolIdInfo = NaElement->new("volume-id-attributes");
	my $nahTag = NaElement->new("tag");
	my $strActiveTag = "";
	my %hshVolUsage;

	# Narrow search to only the requested node if configured by user with the -n option
	if (defined($strVHost)) {
		$nahVolIterator->child_add($nahQuery);
		$nahQuery->child_add($nahVolInfo);
		$nahVolInfo->child_add($nahVolIdInfo);
		$nahVolIdInfo->child_add_string("owning-vserver-name", $strVHost);
	}

	# The active tag is a feature of the NetApp API that allows you to do queries in batches. In this case we are getting records in batches of 100.
	$nahVolIterator->child_add_string("max-records", 100);
	$nahVolIterator->child_add($nahTag);
	while(defined($strActiveTag)) {
	if ($strActiveTag ne "") {
		$nahTag->set_content($strActiveTag);
	}

		$nahVolIterator->child_add_string("max-records", 100);
		# Invoke the request.
		my $nahResponse = $nahStorage->invoke_elem($nahVolIterator);
		validate_ontapi_response($nahResponse, "Failed volume query: ");

		$strActiveTag = $nahResponse->child_get_string("next-tag");
		# Stop if there are no more records.
		if ($nahResponse->child_get_string("num-records") == 0) {
			last;
		}

		# Assign all the retrieved information to a hash.
		foreach my $nahVol ($nahResponse->child_get("attributes-list")->children_get()) {

			my $strVolName = $nahVol->child_get("volume-id-attributes")->child_get_string("name");
			my $strVolOwner = $nahVol->child_get("volume-id-attributes")->child_get_string("owning-vserver-name");
			$strVolName = $strVolOwner . "/" . $strVolName;

			# Don't monitor a volume that is currently being moved as it will result in errors.
			if (defined($nahVol->child_get("volume-state-attributes")->child_get_string("is-moving"))) {
				if ($nahVol->child_get("volume-state-attributes")->child_get_string("is-moving") eq "true") {
					next;
				}
			}

			# Don't check volumes with type TMP (7-Mode Transition Tool)
			if ($nahVol->child_get("volume-id-attributes")->child_get_string("type") eq "tmp") {
				next;
			}

			$hshVolUsage{$strVolName}{'sub'} = "get_volume_space";
			if ($nahVol->child_get("volume-state-attributes")->child_get_string("state") ne "online") {
				$hshVolUsage{$strVolName}{'state'} = $nahVol->child_get("volume-state-attributes")->child_get_string("state");
			} else {
				$hshVolUsage{$strVolName}{'state'} = $nahVol->child_get("volume-state-attributes")->child_get_string("state");
				$hshVolUsage{$strVolName}{'space-total'} = $nahVol->child_get("volume-space-attributes")->child_get_string("size-total");
				if ($debug) {
					if ( $hshVolUsage{$strVolName}{'space-total'} == 0 || $hshVolUsage{$strVolName}{'space-total'} eq '0' ) {
						print "Volume $strVolName reports size-total of 0\n";
						print Dumper($nahVol);
					}
				}
				$hshVolUsage{$strVolName}{'space-used'} = $nahVol->child_get("volume-space-attributes")->child_get_string("size-used");
				$hshVolUsage{$strVolName}{'inodes-total'} = $nahVol->child_get("volume-inode-attributes")->child_get_string("files-total");
				$hshVolUsage{$strVolName}{'inodes-used'} = $nahVol->child_get("volume-inode-attributes")->child_get_string("files-used");
			}
		}
	}

	return \%hshVolUsage;
}

##############################################
## SPACE HELPERS
##############################################

sub calc_space_health {
	# This function controls the logic flow for determining the state of space checks.
	my ($hrefSpaceInfo, $strWarning, $strCritical) = @_;
	my ($hrefWarnThresholds, $hrefCritThresholds) = space_threshold_converter($strWarning, $strCritical);
	my $intState = 0;
	my $intObjectCount = 0;
	my $strOutput;
	my $perfOutput;
	my $hrefObjectState;

	foreach my $strObj (keys %$hrefSpaceInfo) {
		$intObjectCount = $intObjectCount + 1;
		# If the monitored object is not online then test to see if it matches a user defined bad state.
		if ($hrefSpaceInfo->{$strObj}->{'state'} ne "online") {
			if (defined($hrefCritThresholds->{'strings'}) || defined($hrefWarnThresholds->{'strings'})) {
				my $bObjectRemoved = 0;
				foreach my $strStateThresh (@{$hrefCritThresholds->{'strings'}}) {
					if ($hrefSpaceInfo->{$strObj}->{'state'} eq $strStateThresh) {
						my $strNewMessage = $strObj . " is " . $strStateThresh;
						$strOutput = get_nagios_description($strOutput, $strNewMessage);
						$intState = get_nagios_state($intState, 2);
						delete($hrefSpaceInfo->{$strObj});
						$bObjectRemoved = 1;
					}
				}
				if ($bObjectRemoved) {
					next;
				}
				foreach my $strStateThresh (@{$hrefWarnThresholds->{'strings'}}) {
					if ($hrefSpaceInfo->{$strObj}->{'state'} eq $strStateThresh) {
						my $strNewMessage = $strObj . " is " . $strStateThresh;
						$strOutput = get_nagios_description($strOutput, $strNewMessage);
						$intState = get_nagios_state($intState, 1);
						delete($hrefSpaceInfo->{$strObj});
					}
				}
			} elsif ($hrefSpaceInfo->{$strObj}->{'state'} eq "offline") {
				delete($hrefSpaceInfo->{$strObj});
			}
		}

		# Test to see if the monitored object is on it's home node and raise an alert if it is not.
		if (defined($hrefSpaceInfo->{$strObj}->{'home-owner'}) && defined($hrefSpaceInfo->{$strObj}->{'current-owner'})) {
			if ($hrefSpaceInfo->{$strObj}->{'home-owner'} ne $hrefSpaceInfo->{$strObj}->{'current-owner'}) {
				if ($hrefCritThresholds->{'owner'}) {
					my $strNewMessage = $strObj . " not on home! Home: " . $hrefSpaceInfo->{$strObj}->{'home-owner'} . " Current: " . $hrefSpaceInfo->{$strObj}->{'current-owner'};
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, 2);
				} elsif ($hrefWarnThresholds->{'owner'}) {
					my $strNewMessage = $strObj . " not on home! Home: " . $hrefSpaceInfo->{$strObj}->{'home-owner'} . " Current: " . $hrefSpaceInfo->{$strObj}->{'current-owner'};
					$strOutput = get_nagios_description($strOutput, $strNewMessage);
					$intState = get_nagios_state($intState, 1);
				}
			}
		}
	}

	# Test to see if the monitored object has crossed a defined space threshhold.
	unless ( (defined($hrefCritThresholds->{'strings'}) && @{$hrefCritThresholds->{'strings'}}) || (defined($hrefWarnThresholds->{'strings'}) && @{$hrefWarnThresholds->{'strings'}}) || $hrefWarnThresholds->{'owner'} || $hrefCritThresholds->{'owner'} ) {
		($intState, $strOutput, $perfOutput, $hrefSpaceInfo) = space_threshold_helper($intState, $strOutput, $hrefSpaceInfo, $hrefCritThresholds, 2);
		($intState, $strOutput, $perfOutput, $hrefSpaceInfo) = space_threshold_helper($intState, $strOutput, $hrefSpaceInfo, $hrefWarnThresholds, 1);
	}



	# If everything looks ok and no output has been defined then set the message to display OK.
	if (!(defined($strOutput))) {
		$strOutput = "OK - No problem found ($intObjectCount checked)";
	}

	if ((defined($perfOutput))) {
		$strOutput .= $perfOutput;
	}



	return $intState, $strOutput;
}

sub space_threshold_helper {
	# Test the various monitored object values against the thresholds provided by the user.
	my ($intState, $strOutput, $hrefVolInfo, $hrefThresholds, $intAlertLevel) = @_;

	my $perfOutput = "";
	my $perfOutputFinal = " | ";

	foreach my $strVol (keys %$hrefVolInfo) {
		my $bMarkedForRemoval = 0;

		# Don't check an object that has no space
		if (defined($hrefVolInfo->{$strVol}->{'space-total'})) {
			if ($hrefVolInfo->{$strVol}->{'space-total'} == 0 || $hrefVolInfo->{$strVol}->{'space-total'} eq '0') {
				if ($verbose) {
					print "space-total is 0 on $strVol , ignore...\n";
					print Dumper($hrefVolInfo->{$strVol});
				}
				next;
			}
		}
		# Test added by Didier Tollenaers 03/04/2015 updated by Xavier Vallve 28/02/2017
		if ($hrefVolInfo->{$strVol}->{'state'} eq 'online')  {

			# Test if various thresholds are defined and if they are then test if the monitored object exceeds them.
			if (defined($hrefThresholds->{'space-percent'}) || defined($hrefThresholds->{'space-count'})) {
				# Prepare certain variables pre-check to reduce code duplication.
				my $intUsedPercent = ($hrefVolInfo->{$strVol}->{'space-used'} / $hrefVolInfo->{$strVol}->{'space-total'}) * 100;
				$intUsedPercent = floor($intUsedPercent + 0.5);
				my $strReadableUsed = space_to_human_readable($hrefVolInfo->{$strVol}->{'space-used'});
				my $strReadableTotal = space_to_human_readable($hrefVolInfo->{$strVol}->{'space-total'});
				my $strNewMessage = $strVol . " - " . $strReadableUsed . "/" . $strReadableTotal . " (" . $intUsedPercent . "%) SPACE USED";

				if ($intAlertLevel == 1) {
					$perfOutput .= "'" . $strVol . "_usage'=" . $hrefVolInfo->{$strVol}->{'space-used'} . "B;;;0;" . $hrefVolInfo->{$strVol}->{'space-total'} . " ";
				}

				if (defined($hrefThresholds->{'space-percent'}) && defined($hrefThresholds->{'space-count'})) {
					my $intCountInBytes = space_to_bytes($hrefThresholds->{'space-count'});
					my $intCountInPercent = ($intCountInBytes/$hrefVolInfo->{$strVol}->{'space-total'}) * 100;
					$intCountInPercent = floor($intCountInPercent + 0.5);
					my $intPercentInvert = 100 - $hrefThresholds->{'space-percent'};

					if ($intCountInPercent < $intPercentInvert) {
						my $intBytesRemaining = $hrefVolInfo->{$strVol}->{'space-total'} - $hrefVolInfo->{$strVol}->{'space-used'};
						if ($intCountInBytes > $intBytesRemaining) {
							$intState = get_nagios_state($intState, $intAlertLevel);
							$strOutput = get_nagios_description($strOutput, $strNewMessage);
							$bMarkedForRemoval = 1;
						}
					}
					else {
						if ($intUsedPercent >= $hrefThresholds->{'space-percent'}) {
							$intState = get_nagios_state($intState, $intAlertLevel);
							$strOutput = get_nagios_description($strOutput, $strNewMessage);
							$bMarkedForRemoval = 1;
						}
					}
				} elsif (defined($hrefThresholds->{'space-percent'})) {
					if ($intUsedPercent >= $hrefThresholds->{'space-percent'}) {
										$intState = get_nagios_state($intState, $intAlertLevel);
											$strOutput = get_nagios_description($strOutput, $strNewMessage);
											$bMarkedForRemoval = 1;
									}
				} elsif (defined($hrefThresholds->{'space-count'})) {
					my $intCountInBytes = space_to_bytes($hrefThresholds->{'space-count'});
					my $intBytesRemaining = $hrefVolInfo->{$strVol}->{'space-total'} - $hrefVolInfo->{$strVol}->{'space-used'};
					if ($intCountInBytes > $intBytesRemaining) {
										$intState = get_nagios_state($intState, $intAlertLevel);
											$strOutput = get_nagios_description($strOutput, $strNewMessage);
											$bMarkedForRemoval = 1;
									}
				}
			}

			if (defined($hrefThresholds->{'inodes-percent'}) || defined($hrefThresholds->{'inodes-count'})) {
				my $intUsedPercent = ($hrefVolInfo->{$strVol}->{'inodes-used'} / $hrefVolInfo->{$strVol}->{'inodes-total'}) * 100;
				$intUsedPercent = floor($intUsedPercent + 0.5);
				my $strNewMessage = $strVol . " - " . $hrefVolInfo->{$strVol}->{'inodes-used'} . "/" . $hrefVolInfo->{$strVol}->{'inodes-total'} . " (" . $intUsedPercent . "%) INODES USED";

				if ($intAlertLevel == 1) {
					$perfOutput .= "'" . $strVol . "_inodes'=" . $hrefVolInfo->{$strVol}->{'inodes-used'} . "B;;;0;" . $hrefVolInfo->{$strVol}->{'inodes-total'} . " ";
				}

				if (defined($hrefThresholds->{'inodes-percent'}) && defined($hrefThresholds->{'inodes-count'})) {
					my $intPercentInInodes = $hrefVolInfo->{$strVol}->{'inodes-total'} * ($hrefThresholds->{'inodes-percent'}/100);

					if ($hrefThresholds->{'inodes-count'} < $intPercentInInodes) {
						my $intInodesRemaining = $hrefVolInfo->{$strVol}->{'inodes-total'} - $hrefVolInfo->{$strVol}->{'inodes-used'};
						if ($hrefThresholds->{'inodes-count'} > $intInodesRemaining) {
							$intState = get_nagios_state($intState, $intAlertLevel);
													$strOutput = get_nagios_description($strOutput, $strNewMessage);
													$bMarkedForRemoval = 1;
						}
					} else {
						if ($intUsedPercent >= $hrefThresholds->{'inodes-percent'}) {
							$intState = get_nagios_state($intState, $intAlertLevel);
													$strOutput = get_nagios_description($strOutput, $strNewMessage);
													$bMarkedForRemoval = 1;
						}
					}
				} elsif (defined($hrefThresholds->{'inodes-percent'})) {
					if ($intUsedPercent >= $hrefThresholds->{'inodes-percent'}) {
										$intState = get_nagios_state($intState, $intAlertLevel);
											$strOutput = get_nagios_description($strOutput, $strNewMessage);
											$bMarkedForRemoval = 1;
									}
				} elsif (defined($hrefThresholds->{'inodes-count'})) {
					my $intInodesRemaining = $hrefVolInfo->{$strVol}->{'inodes-total'} - $hrefVolInfo->{$strVol}->{'inodes-used'};

					if ($hrefThresholds->{'inodes-count'} > $intInodesRemaining) {
										$intState = get_nagios_state($intState, $intAlertLevel);
											$strOutput = get_nagios_description($strOutput, $strNewMessage);
											$bMarkedForRemoval = 1;
									}
				}
			}

			# Remove problems from list so that it's not altered by further monitoring (I.e. warnings overwriting critical problems)
			if ($bMarkedForRemoval) {
				delete($hrefVolInfo->{$strVol});
			}
		}
	}

	if ($intAlertLevel == 1) {
		#print "perfOutput: " . $perfOutput . "\n";
		$perfOutputFinal .= $perfOutput;
	}

	return $intState, $strOutput, $perfOutputFinal, $hrefVolInfo;
}

sub space_threshold_converter {
	# Determine what thresholds have been provided by the user for space monitoring.
	my ($strWarning, $strCritical) = @_;
	my (%hshWarnThresholds, %hshCritThresholds, @aryWarning, @aryCritical, @aryStringsTemp);

	if (defined($strWarning)) {
		@aryWarning = split(",", $strWarning);
	}

	if (defined($strCritical)) {
		@aryCritical = split(",", $strCritical);
	}

	$hshWarnThresholds{'owner'} = 0;
	$hshCritThresholds{'owner'} = 0;

	# Use regex to match the various possible values for space monitoring and assign the values to the relevant hash element.
	foreach my $strWarnThresh (@aryWarning) {
		if ($strWarnThresh =~ m/^[0-9]*\%$/) {
			$hshWarnThresholds{'space-percent'} = $strWarnThresh;
			$hshWarnThresholds{'space-percent'} =~ s/%//;
		} elsif ($strWarnThresh =~ m/^([0-9]*)([KMGT]?B)/) {
			$hshWarnThresholds{'space-count'} = $strWarnThresh;
		} elsif ($strWarnThresh =~ m/^[0-9]*\%i$/) {
			$hshWarnThresholds{'inodes-percent'} = $strWarnThresh;
			$hshWarnThresholds{'inodes-percent'} =~ s/\%i//;
		} elsif ($strWarnThresh =~ m/^[0-9]*$/) {
			$hshWarnThresholds{'inodes-count'} = $strWarnThresh;
		} elsif ($strWarnThresh =~ m/^owner|is-home$/) {
			$hshWarnThresholds{'owner'} = 1;
		} elsif ($strWarnThresh =~ m/^[a-zA-Z]*$/) {
			push(@aryStringsTemp, $strWarnThresh);
		}
	}

	# Push an array of invalid states for the monitored object to be in to the threshold hash if any have been defined.
	$hshWarnThresholds{'strings'} = [@aryStringsTemp];
	undef(@aryStringsTemp);

	# Use regex to match the various possible values for space monitoring and assign the values to the relevant hash element.
	foreach my $strCritThresh (@aryCritical) {
		if ($strCritThresh =~ m/^[0-9]*\%$/) {
			$hshCritThresholds{'space-percent'} = $strCritThresh;
			$hshCritThresholds{'space-percent'} =~ s/%//;
		} elsif ($strCritThresh =~ m/^([0-9]*)([KMGT]?B)/) {
			$hshCritThresholds{'space-count'} = $strCritThresh;
		} elsif ($strCritThresh =~ m/^[0-9]*\%i$/) {
			$hshCritThresholds{'inodes-percent'} = $strCritThresh;
			$hshCritThresholds{'inodes-percent'} =~ s/\%i//;
		} elsif ($strCritThresh =~ m/^[0-9]*$/) {
			$hshCritThresholds{'inodes-count'} = $strCritThresh;
		} elsif ($strCritThresh =~ m/^owner|is-home$/) {
			$hshCritThresholds{'owner'} = 1;
		} elsif ($strCritThresh =~ m/^[a-zA-Z]*$/) {
			push(@aryStringsTemp, $strCritThresh);
		}
	}

	# Push an array of invalid states for the monitored object to be in to the threshold hash if any have been defined.
	$hshCritThresholds{'strings'} = [@aryStringsTemp];
	return \%hshWarnThresholds, \%hshCritThresholds;
}

sub space_to_bytes {
	# Convert human readable magnitude to bytes.
	my $strInput = shift;
	$strInput =~ m/([0-9]*)([KMGT]?B)/;
	my $intValue = $1;
	my $strMagnitude = $2;

	if ($strMagnitude eq "KB") {
		$intValue = $intValue * 1024;
	} elsif ($strMagnitude eq "MB") {
		$intValue = $intValue * (1024 ** 2);
	} elsif ($strMagnitude eq "GB") {
		$intValue = $intValue * (1024 ** 3);
	} elsif ($strMagnitude eq "TB") {
		$intValue = $intValue * (1024 ** 4);
	} else {
		print "No magnitude (B, KB, MB, GB, TB) defined, unable to finish!\n";
		exit 3;
	}

	return $intValue;
}

sub space_to_human_readable {
	# Convert bytes to human readable magnitude
	my $intValue = shift;

	my @aryStrings = ("B","KB","MB","GB","TB");
	my $intCount = 0;

	while (($intValue > 1024) && ($intCount < 4)) {
		$intValue = $intValue / 1024;
		$intCount = $intCount + 1;
	}

	# Round the output so that it's a whole value only.
	my $strRoundedNumber = sprintf("%0.2f", $intValue) . $aryStrings[$intCount];

	return $strRoundedNumber;
}

##############################################
## HELPERS
##############################################

sub help {
	# It helps :) I hope.
	my $strVersion = "v3.01.171611";
	print "\ncheck_netapp_ontapi version: $strVersion\n";
	print "By John Murphy <john.murphy\@roshamboot.org>, Willem D'Haese <willem.dhaese\@gmail.com>, GNU GPL License\n";
	print "\nUsage: ./check_netapp_ontapi.pl -H <hostname> -u <username> -p <password> -o <option> [ -w <warning_thresh> -c <critical_thresh> -m <include|exclude,pattern1,pattern2,etc> ]\n\n";
	print <<EOL;
--hostname, -H
	Hostname or address of the cluster administrative interface.
--node, -n
	Name of a vhost or cluster-node to restrict this query to.
--user, -u
	Username of a Netapp Ontapi enabled user.
--password, -p
	Password for the netapp Ontapi enabled user.
--option, -o
	The name of the option you want to check. See the option and threshold list at the bottom of this help text.
--suboption, -s
	If available for the option, allow to specify the list of the checks to perform.
--warning, -w
	A custom warning threshold value. See the option and threshold list at the bottom of this help text.
--critical, -c
	A custom warning threshold value. See the option and threshold list at the bottom of this help text.
--modifier, -m
	This modifier is used to set an inclusive or exclusive filter on what you want to monitor.
--report, -r
	The output format. Can be "short", "long" (default), or "html"
--verbose, --debug, --trace
	Debug output options
--help, -h
	Display this help text.

===OPTION LIST===
volume_health
	desc: Check the space and inode health of a vServer volume. If space % and space in *B are both defined the smaller value of the two will be used when deciding if the volume is in a warning or critical state. This allows you to better accomodate large volume monitoring. Separate values with comma.
	thresh: Space % used, space in *B (i.e MB) remaining, inode count remaining, inode % used (Usage example: 80%i), "offline" keyword.
	node: The node option restricts this check by vserver name.

aggregate_health
	desc: Check the space and inode health of a cluster aggregate. If space % and space in *B are both defined the smaller value of the two will be used when deciding if the volume is in a warning or critical state. This allows you to better accomodate large aggregate monitoring. Separate values with comma.
	thresh: Space % used, space in *B (i.e MB) remaining, inode count remaining, inode % used (Usage example: 80%i), "offline" keyword, "is-home" keyword.
	node: The node option restricts this check by cluster-node name.

snapshot_health
	desc: Check the space and inode health of a vServer snapshot. If space % and space in *B are both defined the smaller value of the two will be used when deciding if the volume is in a warning or critical state. This allows you to better accomodate large snapshot monitoring. Separate values with comma.
	thresh: Space % used, space in *B (i.e MB) remaining, inode count remaining, inode % used (Usage example: 80%i), "offline" keyword.
	node: The node option restricts this check by vserver name.

quota_health
	desc: Check that the space and file thresholds have not been crossed on a quota.
	thresh: N/A storage defined.
	node: The node option restricts this check by vserver name.

snapmirror_health
	desc: Check the lag time and health flag of the snapmirror relationships.
	thresh: Snapmirror lag time (valid intervals are s, m, h, d).
	node: The node options restricts this check by snapmirror destination cluster-node name.

filer_hardware_health
	desc: Check the environment hardware health of the filers (fan, psu, temperature, battery).
	thresh: Component name (fan, psu, temperature, battery). There is no default alert level they MUST be defined.
	node: The node option restricts this check by cluster-node name.

port_health
	desc: Checks the state of a physical network port.
	thresh: N/A not customizable.
	node: The node option restricts this check by cluster-node name.

vscan_health
	desc: Check if vscan is disabled
	thresh: N/A not customizable.
	node: The node option restricts this check by vserver name.

interface_health
	desc: Check that a LIF is in the correctly configured state and that it is on its home node and port.
	thresh: N/A not customizable.
	node: The node option restricts this check by vserver name.
	suboption: status, home-node, home-port

netapp_alarms
	desc: Check for Netapp console alarms.
	thresh: N/A not customizable.
	node: The node option restricts this check by cluster-node name.
	(This is not available in ONTAP > 9)

cluster_health
	desc: Check the cluster disks for failure or other potentially undesirable states.
	thresh: N/A not customizable.
	node: The node option restricts this check by cluster-node name.

clusternode_health
	desc: Check the cluster-nodes for unhealthy conditions
	thresh: N/A not customizable.
	node: The node option restricts this check by cluster-node name.

disk_health
	desc: Check the health of the disks in the cluster.
	thresh: Not customizable yet.
	node: The node option restricts this check by cluster-node name.

disk_spare
	desc: Check the number of spare disks
	thresh: Warning / critical required spare disks. Default thresholds are 2 / 1.
	node: The node option restricts this check by cluster-node name.

* For keyword thresholds, if you want to ignore alerts for that particular keyword you set it at the same threshold that the alert defaults to.

EOL
	exit 3;
}

sub time_to_seconds {
	# Convert human readable time frame D H M S to seconds.
	my $strInput = shift;

	# Use regex back references to seperate the value from the magnitude.
	$strInput =~ m/([0-9]*)([smhd])/;
	my $intValue = $1;
	my $strMagnitude = $2;

	if ($strMagnitude eq "s") {
		# Do nothing
	} elsif ($strMagnitude eq "m") {
		$intValue = $intValue * 60;
	} elsif ($strMagnitude eq "h") {
		$intValue = $intValue * (60 ** 2);
	} elsif ($strMagnitude eq "d") {
		$intValue = ($intValue * 24) * (60 ** 2);
	} else {
		print "No time valid time string (s, m, h, d) defined, unable to finish!\n";
		exit 3;
	}

	return int($intValue);
}

sub seconds_to_time {
	# Convert seconds to human readable time frame D H M S
	my $intSecondsIn = shift;
	my $intDays = int($intSecondsIn / 86400);
	$intSecondsIn = $intSecondsIn - ($intDays * 86400);
	my $intHours = int($intSecondsIn / 3600);
	$intSecondsIn = $intSecondsIn - ($intHours * 3600);
	my $intMinutes = int($intSecondsIn / 60);
	my $intSeconds = $intSecondsIn % 60;

	my $strDays = $intDays < 1 ? "" : $intDays . "d ";
	my $strHours = $intHours < 1 ? "" : $intHours . "h ";
	my $strMinutes = $intMinutes < 1 ? "" : $intMinutes . "m ";
	my $strSeconds = $intSeconds . "s";
	my $strTime = $strDays . $strHours . $strMinutes . $strSeconds;

	return $strTime;
}

sub get_nagios_description {
	# Helper function to concatenate output messages
	my ($strOutput, $strNewMessage) = @_;
	if (!(defined($strOutput))) {
		$strOutput = $strNewMessage;
	} else {
		$strOutput .= ", " . $strNewMessage;
	}

	return $strOutput;
}

sub get_nagios_multiline {
	# Helper function to concatenate multiline output messages
	my ($strOutput, $strNewMessage) = @_;
	if (!(defined($strOutput))) {
		$strOutput = $strNewMessage;
	} else {
		$strOutput .= "<br>" . $strNewMessage;
	}

	return $strOutput;
}

sub get_nagios_state {
	# Helper function to change the state only if the new state is worse than the last one provided.
	my ($intState, $intNewState) = @_;
	if ($intNewState > $intState) {
		$intState = $intNewState;
	}

	return $intState;
}

sub validate_ontapi_response {
	my ($nahResponse, $strMessage) = @_;

	if ($trace) {
		print Dumper($nahResponse);
	}

	# Validate the response from the API to ensure that it doesn't contain any errors and if it does fail gracefully.
	if (ref($nahResponse) eq "NaElement" && $nahResponse->results_errno != 0) {
		my $strResponse = $nahResponse->results_reason();
		print $strMessage . $strResponse . "\n";
		exit 3;
	} elsif ($nahResponse->results_status() eq "failed") {
		my $strResponse = $nahResponse->results_reason();
		print $strResponse . "\n";
		exit 3;
	} else {
		return;
	}
}

sub filter_object {
	# Take the user input and put it into an array and slice of the first array element which should contain the filtering type.
	my ($hrefObjectsToFilter, $strModifier) = @_;
	my @aryModifier = split(",",$strModifier);
	my $strProcType = shift @aryModifier;

	# Perform inclusive or exclusive filtering depending on what the user requested.
	if ($strProcType eq "exclude") {
		# Remove every object from the monitoring list that contains the string provided by the user.
		foreach my $strObject (keys %$hrefObjectsToFilter) {
			foreach my $strFilter (@aryModifier) {
				if ($strObject =~ m/$strFilter/) {
					delete($hrefObjectsToFilter->{$strObject});
				}
			}
		}
	} elsif ($strProcType eq "include") {
		# Remove every object from the monitoring list that doesn't contain the string provided by the user.
		foreach my $strObject (keys %$hrefObjectsToFilter) {
			my $bRemove = 1;

			foreach my $strFilter (@aryModifier) {
				if ($strObject =~ m/$strFilter/) {
					$bRemove = 0;
				}
			}

			if ($bRemove) {
				delete($hrefObjectsToFilter->{$strObject});
			}
		}
	} else {
		print "Unable to determine modifier type, should be either include or exclude... skipping filtering step.\n";
		exit 3;
	}

	return $hrefObjectsToFilter;
}

# Generic check function: call the getvals function to obtain data,
# optionally filter its result, finally call the calc function to perform
# the check against levels and return its result
sub check {
    my ($getvals, $calc, $args) = @_;

    my $obj = $getvals->( @$args{qw/ storage vhost warn crit/} );
    $obj = filter_object( $obj, $args->{modifier} ) if defined $args->{modifier};
    return $calc->( $obj, @$args{qw/ warn crit subopt report/} );
}

# Add default warn/crit levels if they should be undefined
sub deflvl {
    my ($args, $def_warn, $def_crit) = @_;
    $args->{warn} //= $def_warn;
    $args->{crit} //= $def_crit;
    return $args;
}

my %CHECKS = (
    volume_health => sub { check( \&get_volume_space, \&calc_space_health, deflvl( shift, "80%", "95%" )) },
    aggregate_health => sub { check( \&get_aggregate_space, \&calc_space_health, deflvl( shift, "80%", "95%" )) },
    snapshot_health => sub { check( \&get_snap_space, \&calc_space_health, deflvl( shift, "80%", "95%" )) },
    quota_health => sub { check( \&get_quota_space, \&calc_quota_health, deflvl( shift, "80%", "95%" )) },
    snapmirror_health => sub { check( \&get_snapmirror_lag, \&calc_snapmirror_health, shift ) },
    filer_hardware_health => sub { check( \&get_filer_hardware, \&calc_filer_hardware_health, shift ) },
    interface_health => sub { check( \&get_interface_health, \&calc_interface_health, shift ) },
    port_health => sub { check( \&get_port_health, \&calc_interface_health, shift ) },
    vscan_health => sub { check( \&get_vscan_info, \&calc_vscan_health, shift ) },
    cluster_health => sub { check( \&get_cluster_health, \&calc_cluster_health, shift ) },
    clusternode_health => sub { check( \&get_cluster_node_health, \&calc_cluster_node_health, shift ) },
    disk_health => sub { check( \&get_disk_info, \&calc_disk_health, shift ) },
    disk_spare => sub {
        my $args = shift;
        check(
            sub { get_spare_info   ( shift, $args->{vhost}, @_ ) },
            sub { calc_spare_health( shift, $args->{vhost}, @_ ) },
            deflvl( $args, 1, 2 )
        )
    },
    netapp_alarms => sub {
        my $args = shift;
        $args->{apiver} >= 900
            and return ( 0 ,"OK: Ontapi >9 does not support dashboard and dashboard alarms any more." );
        check( \&get_netapp_alarms, \&calc_netapp_alarm_health, $args )
    },
    ## FUTURE STUFF----
    # DISK IO, DE-DUPE LAG

);


##############################################
##
## BEGIN MAIN
##
##############################################

# Declare and configure option selections
my ($strHost, $strVHost, $strUser, $strPassword, $strOption, $strSuboption, $strWarning, $strCritical, $strModifier, $strReport);
$strSuboption = undef;
$strReport = "long";

GetOptions(
	"hostname|H=s" => \$strHost,
	"node|n=s" => \$strVHost,
	"user|u=s" => \$strUser,
	"password|p=s" => \$strPassword,
	"option|o=s" => \$strOption,
	"suboption|s=s" => \$strSuboption,
	"warning|w=s" => \$strWarning,
	"critical|c=s" => \$strCritical,
	"modifier|m=s" => \$strModifier,
	"report|r=s" => \$strReport,
	"verbose" => \$verbose,
	"debug" => \$debug,
	"trace" => \$trace,
);

# Print help if a required field is not entered or if help is requested.
unless ($strHost && $strUser && $strPassword && $strOption) {
	print "A required option is not set!\n";
	help();
}
# Convert to lowercase to prevented unexpected things happening while trying to match the option.
$strOption = lc($strOption);

# Create the NetApp API handle and test that the connection works.
my $nahStorage = NaServer->new($strHost, 1, 15);
$nahStorage->set_style("LOGIN");
$nahStorage->set_admin_user($strUser, $strPassword);
$nahStorage->set_transport_type("HTTPS");
my $nahResponse = $nahStorage->invoke("system-get-version");
validate_ontapi_response($nahResponse, "Failed test query: ");

# Get ontapi version
my $ontapiGeneration = $nahResponse->child_get("version-tuple")->child_get("system-version-tuple")->child_get_string("generation");
my $ontapiMajor = $nahResponse->child_get("version-tuple")->child_get("system-version-tuple")->child_get_string("major");
my $ontapiMinor = $nahResponse->child_get("version-tuple")->child_get("system-version-tuple")->child_get_string("minor");
my $intOntapiVersion = int($ontapiGeneration . $ontapiMajor . $ontapiMinor);
my $strOntapiVersion= $ontapiGeneration . '.' . $ontapiMajor . '.' . $ontapiMinor;

if ($debug) {
	print "Ontapi version: $strOntapiVersion\n";
}

# Test that the filer is running in clustered mode instead of 7-Mode, exit if it is not.
if (!($nahResponse->child_get_string("is-clustered"))) {
	print "This plugin only works for Cluster-Mode your filers are running in 7-Mode.\n";
	exit 3;
}

my $checkfunc = $CHECKS{ $strOption } or die "Unknown check '$strOption'";
my ($intState, $strOutput) = $checkfunc->(
    {
        modifier => $strModifier,
        warn => $strWarning,
        crit => $strCritical,
        subopt => $strSuboption,
        report => $strReport,
        storage => $nahStorage,
        vhost => $strVHost,
        apiver => $intOntapiVersion
    }
);

# Print the output and exit with the resulting state.
print "$strOutput\n";
exit $intState;
