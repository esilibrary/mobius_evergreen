#!/usr/bin/perl
use lib qw(../);
use MARC::Record;
use MARC::File;
use MARC::File::XML (BinaryEncoding => 'utf8');
use File::Path qw(make_path remove_tree);
use strict; 
use Loghandler;
use Mobiusutil;
use DBhandler;
use Data::Dumper;
use email;
use DateTime;
use utf8;
use Encode;
use DateTime;
use LWP::Simple;
use OpenILS::Application::AppUtils;
use DateTime::Format::Duration;
use Digest::SHA1;
use XML::Simple;
use Unicode::Normalize;


my $configFile = @ARGV[0];

my $xmlconf = "/openils/conf/opensrf.xml";

if(! -e $xmlconf)
{
	print "I could not find the xml config file: $xmlconf\n";
	exit 0;
}

 if(!$configFile)
 {
	print "Please specify a config file\n";
	exit;
 }

	our $mobUtil = new Mobiusutil();  
	my $conf = $mobUtil->readConfFile($configFile);
	our $jobid=-1;
	our $log;
	our $dbHandler;
	our $audio_book_score_when_audiobooks_dont_belong;
	our $electronic_score_when_bib_is_considered_electronic;
	our @electronicSearchPhrases;
	our @audioBookSearchPhrases;
	our @microficheSearchPhrases;
	our @microfilmSearchPhrases;
	our @videoSearchPhrases;
	our @largePrintBookSearchPhrases;
	our @musicSearchPhrases;
	our @playawaySearchPhrases;
	our @seekdestroyReportFiles =();
	our %queries;
	our %conf;
	our $baseTemp;
  
 if($conf)
 {
	%conf = %{$conf};
	
	if ($conf{"logfile"})
	{
		my $dt = DateTime->now(time_zone => "local"); 
		my $fdate = $dt->ymd;
		my $ftime = $dt->hms;
		my $dateString = "$fdate $ftime";
	
		$log = new Loghandler($conf->{"logfile"});
		$log->truncFile("");
		$log->addLogLine(" ---------------- Script Starting ---------------- ");
		print "Executing job  tail the log for information (".$conf{"logfile"}.")\n";
		my @reqs = ("logfile","tempdir",); 
		my $valid = 1;
		my $errorMessage="";
		for my $i (0..$#reqs)
		{
			if(!$conf{@reqs[$i]})
			{
				$log->addLogLine("Required configuration missing from conf file");
				$log->addLogLine(@reqs[$i]." required");
				$valid = 0;
			}
		}
		if($valid)
		{	
			my %dbconf = %{getDBconnects($xmlconf)};
			$dbHandler = new DBhandler($dbconf{"db"},$dbconf{"dbhost"},$dbconf{"dbuser"},$dbconf{"dbpass"},$dbconf{"port"});
			$baseTemp = $conf{"tempdir"};
			$baseTemp =~ s/\/$//;
			$baseTemp.='/';
			
			my $afterProcess = DateTime->now(time_zone => "local");
			my $difference = $afterProcess - $dt;
			my $format = DateTime::Format::Duration->new(pattern => '%M:%S');
			my $duration =  $format->format_duration($difference);
			my @tolist = ($conf{"alwaysemail"});
			if(length($errorMessage)==0) #none of the code currently sets an errorMessage but maybe someday
			{
				my $email = new email($conf{"fromemail"},\@tolist,$valid,1,\%conf);
				my @reports = @{reportResults()};
				if($#reports>-1)
				{
					my @attachments = (@{@reports[1]}, @seekdestroyReportFiles);
					my $reports = @reports[0];
					$email->sendWithAttachments("Circ Report: Unfillable Holds","$reports\r\n\r\n-MOBIUS Perl Squad-",\@attachments);
					foreach(@attachments)
					{
						unlink $_ or warn "Could not remove $_\n";
					}
				}
				
			}
			elsif(length($errorMessage)>0)
			{
				my @tolist = ($conf{"alwaysemail"});
				my $email = new email($conf{"fromemail"},\@tolist,1,0,\%conf);
				$email->send("Circ Report: Unfillable Holds","$errorMessage\r\n\r\n-Evergreen Perl Squad-");
			}
		}
		$log->addLogLine(" ---------------- Script Ending ---------------- ");
	}
	else
	{
		print "Config file does not define 'logfile'\n";		
	}
}

sub reportResults
{
	my $unfills='';
	my $longtransit='';
	my $partholddeletes='';	
	my $metaholddeletes='';	
	my @attachments=();
	my $ret;
	my @returns;
	
	my $query = "
	select ahr.id,acard.barcode,ahr.target,ahr.hold_type,ahr.request_time,aou.name from
action.hold_request ahr,
actor.usr au,
actor.org_unit aou,
actor.card acard
where
aou.id=ahr.pickup_lib and
acard.active='t' and
acard.usr = au.id and
au.id=ahr.usr and
ahr.fulfillment_time is null and
ahr.cancel_time is null and
ahr.expire_time is null and
ahr.capture_time is null and
ahr.current_copy is null and
not ahr.frozen and
ahr.request_time<now()-\$\$200 days\$\$::interval and 
ahr.id not in(select hold from action.hold_copy_map)
order by aou.name,ahr.request_time";
$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$line = $mobUtil->insertDataIntoColumn($line,@row[2],29);
		$line = $mobUtil->insertDataIntoColumn($line,@row[3],39);
		$line = $mobUtil->insertDataIntoColumn($line,@row[4],43);
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[5],54);
		$unfills.="$line\r\n";
		$count++;
	}
	if($count>0)
	{
		my $headerForEmail = "Hold ID";
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Patron Barcode",11);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Target",29);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"HT",39);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Rqst Time",43);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail," Pickup Library",54);
	
		$unfills = $headerForEmail."\r\n$unfills";
		$unfills="Holds with no copies and requested more than 200 days ago\r\nTotal: $count
		Hold Type key: T=Title,V=Volume,C=Copy,P=Part,M=Metarecord\r\n$unfills\r\n\r\n\r\n";
		$unfills = truncateOutput($unfills,7000);
		my @header = ("Hold ID","Patron Barcode","Target","Hold Type","Request Time","Pickup Library");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."Unfillable_holds.csv");
		push(@attachments,$baseTemp."Unfillable_holds.csv");
	}
	
	my $query = "
	select ahr.id,acard.barcode,ahr.target,ahr.hold_type,ahr.request_time::date,ac.barcode,ahtc.source_send_time::date,sendinglib.shortname,pickuplib.shortname from 
action.hold_request ahr,
actor.usr au,
actor.org_unit pickuplib,
actor.org_unit sendinglib,
actor.card acard,
asset.copy ac,
action.hold_transit_copy ahtc
where
pickuplib.id=ahr.pickup_lib and
sendinglib.id=ahtc.source and
acard.active='t' and
acard.usr = au.id and
au.id=ahr.usr and
ahr.current_copy=ac.id and
ahtc.hold=ahr.id and
ahr.fulfillment_time is null and
ahr.cancel_time is null and
ahr.expire_time is null and
ahr.capture_time is not null and
ahtc.dest_recv_time is null and
not ac.deleted and
ahtc.source_send_time<now()-\$\$31 days\$\$::interval and
ac.status_changed_time<now()-\$\$31 days\$\$::interval and
ac.status=6
order by pickuplib.shortname,ahr.request_time
";
$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$line = $mobUtil->insertDataIntoColumn($line,@row[2],29);
		$line = $mobUtil->insertDataIntoColumn($line,@row[3],39);
		$line = $mobUtil->insertDataIntoColumn($line,@row[4],43);
		$line = $mobUtil->insertDataIntoColumn($line,@row[5],56);
		$line = $mobUtil->insertDataIntoColumn($line,@row[6],73);		
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[7],85);
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[8],96);
		$longtransit.="$line\r\n";
		$count++;
	}
	if($count>0)
	{
		my $headerForEmail = "Hold ID";
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Patron Barcode",11);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Target",29);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"HT",39);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Rqst Time",43);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Copy Barcode",56);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Send Date",73);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Sndng Lib",85);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Dest Lib",96);
		
		$longtransit = $headerForEmail."\r\n$longtransit";
		$longtransit="Holds in transit for more than 31 days\r\nTotal: $count
		Hold Type key: T=Title,V=Volume,C=Copy,P=Part,M=Metarecord\r\n$longtransit\r\n\r\n\r\n";
		$longtransit = truncateOutput($longtransit,7000);
		my @header = ("Hold ID","Patron Barcode","Target","Hold Type","Request Time","Copy Barcode","Send Date","Sending Library","Destination Library");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."Long_transit_holds.csv");
		push(@attachments,$baseTemp."Long_transit_holds.csv");
	}
	
	my $query = "
select ahr.id,acard.barcode,ahr.target,ahr.hold_type,ahr.request_time,aou.name from
action.hold_request ahr,
actor.usr au,
actor.org_unit aou,
actor.card acard
where
ahr.hold_type='P' and
aou.id=ahr.pickup_lib and
acard.active='t' and
acard.usr = au.id and
au.id=ahr.usr and
ahr.fulfillment_time is null and
ahr.cancel_time is null and
ahr.expire_time is null and
ahr.capture_time is null and
ahr.current_copy is null and
ahr.target not in(select id from biblio.monograph_part)
order by aou.name,ahr.request_time";
$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$line = $mobUtil->insertDataIntoColumn($line,@row[2],29);
		$line = $mobUtil->insertDataIntoColumn($line,@row[3],39);
		$line = $mobUtil->insertDataIntoColumn($line,@row[4],43);
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[5],54);
		$partholddeletes.="$line\r\n";
		$count++;
		$query = "DELETE FROM ACTION.HOLD_REQUEST WHERE ID=\$1";
		$log->addLine($query.@row[0]);
		my @values = (@row[0]);
		$dbHandler->updateWithParameters($query,\@values);
	}
	if($count>0)
	{
		my $headerForEmail = "Hold ID";
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Patron Barcode",11);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Target",29);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"HT",39);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Rqst Time",43);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail," Pickup Library",54);
	
		$partholddeletes = $headerForEmail."\r\n$partholddeletes";
		$partholddeletes=
"--- Part Level holds for Parts that do not exist in the database ---
WARNING: These holds have been removed from the database.
		The Part no longer exists and we have no way of knowing the intended target.
		You may contact the patron to explain that a hold was removed.\r\nTotal: $count
\r\n$partholddeletes\r\n\r\n\r\n";
		$partholddeletes = truncateOutput($partholddeletes,7000);
		my @header = ("Hold ID","Patron Barcode","Target","Hold Type","Request Time","Pickup Library");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."Deleted_broken_part_level_holds.csv");
		push(@attachments,$baseTemp."Deleted_broken_part_level_holds.csv");
	}
	
	my $query = "
select ahr.id,acard.barcode,ahr.target,ahr.hold_type,ahr.request_time,aou.name from
action.hold_request ahr,
actor.usr au,
actor.org_unit aou,
actor.card acard
where
ahr.hold_type='M' and
aou.id=ahr.pickup_lib and
acard.active='t' and
acard.usr = au.id and
au.id=ahr.usr and
ahr.fulfillment_time is null and
ahr.cancel_time is null and
ahr.expire_time is null and
ahr.capture_time is null and
ahr.current_copy is null and
ahr.target not in(select id from metabib.metarecord)
order by aou.name,ahr.request_time";
$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$line = $mobUtil->insertDataIntoColumn($line,@row[2],29);
		$line = $mobUtil->insertDataIntoColumn($line,@row[3],39);
		$line = $mobUtil->insertDataIntoColumn($line,@row[4],43);
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[5],54);
		$metaholddeletes.="$line\r\n";
		$count++;
		$query = "DELETE FROM ACTION.HOLD_REQUEST WHERE ID=\$1";
		$log->addLine($query.@row[0]);
		my @values = (@row[0]);
		$dbHandler->updateWithParameters($query,\@values);
	}
	if($count>0)
	{
		my $headerForEmail = "Hold ID";
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Patron Barcode",11);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Target",29);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"HT",39);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"Rqst Time",43);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail," Pickup Library",54);
	
		$metaholddeletes = $headerForEmail."\r\n$metaholddeletes";
		$metaholddeletes=
"--- Metarecord Level holds for Metarecord that do not exist in the database ---
WARNING: These holds have been removed from the database.
		The Metarecord no longer exists and we have no way of knowing the intended target.
		You may contact the patron to explain that a hold was removed.\r\nTotal: $count
\r\n$metaholddeletes\r\n\r\n\r\n";
		$metaholddeletes = truncateOutput($metaholddeletes,7000);
		my @header = ("Hold ID","Patron Barcode","Target","Hold Type","Request Time","Pickup Library");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."Deleted_broken_metarecord_holds.csv");
		push(@attachments,$baseTemp."Deleted_broken_metarecord_holds.csv");
	}
	
	$ret.=$unfills.$longtransit.$partholddeletes.$metaholddeletes."\r\n\r\nPlease see attached spreadsheets for full details";	
	@returns = ($ret,\@attachments);
	my @ret = ();
	return \@returns;
	
	#This is saved for later. This query shows hold transit time averages
	$query="select aou_send.name,aou_rec.name, avg(dest_recv_time - source_send_time), min(dest_recv_time - source_send_time),max(dest_recv_time - source_send_time),count(*)  from action.hold_transit_copy ahtc, actor.org_unit aou_send, actor.org_unit aou_rec
where
ahtc.source=aou_send.id and
ahtc.dest=aou_rec.id
group by
aou_send.name,aou_rec.name
order by aou_send.name,aou_rec.name";


}

sub createCSVFileFrom2DArray
{
	my @results = @{@_[0]};
	my $fileName = @_[1];
	my $fileWriter = new Loghandler($fileName);
	$fileWriter->deleteFile();
	my $output = "";
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $csvLine = $mobUtil->makeCommaFromArray(\@row,);
		$output.=$csvLine."\n";
	}
	$fileWriter->addLine($output);
	return $output;
}

sub truncateOutput
{
	my $ret = @_[0];
	my $length = @_[1];
	if(length($ret)>$length)
	{
		$ret = substr($ret,0,$length)."\nTRUNCATED FOR LENGTH\n\n";
	}
	return $ret;
}

sub getDBconnects
{
	my $openilsfile = @_[0];
	my $xml = new XML::Simple;
	my $data = $xml->XMLin($openilsfile);
	my %conf;
	$conf{"dbhost"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{host};
	$conf{"db"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{db};
	$conf{"dbuser"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{user};
	$conf{"dbpass"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{pw};
	$conf{"port"}=$data->{default}->{apps}->{"open-ils.storage"}->{app_settings}->{databases}->{database}->{port};
	##print Dumper(\%conf);
	return \%conf;

}

 exit;

 
 