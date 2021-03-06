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



# 007 byte 4: v=DVD b=VHS s=Blueray
# substr(007,4,1)
# Blue-ray:
# http://missourievergreen.org/eg/opac/record/586602?query=c;qtype=keyword;fi%3Asearch_format=blu-ray;locg=1
# vd uscza-
# DVD:
# missourievergreen.org/eg/opac/record/1066653?query=c;qtype=keyword;fi%3Asearch_format=dvd;locg=1
# vd mvaizu
# VHS:
# http://missourievergreen.org/eg/opac/record/604075?query=c;qtype=keyword;fi%3Asearch_format=vhs;locg=1
# vf-cbahou

# Playaway query chunk:
# (
		# (
		# split_part(marc,$$tag="007">$$,3) ~ 'sz' 
		# and 
		# split_part(marc,$$tag="007">$$,2) ~ 'cz' 
		# )
	# or
		# (
		# split_part(marc,$$tag="007">$$,2) ~ 'sz' 
		# and 
		# split_part(marc,$$tag="007">$$,3) ~ 'cz' 
		# )
	# )
	
	# Find Biblio.record_entry without opac icons:
# select id from biblio.record_entry where not deleted and 
# id not in(select id from metabib.record_attr_flat where attr='icon_format')
# 32115 rows

my $configFile = @ARGV[0];

my $xmlconf = "/openils/conf/opensrf.xml";
our $dryrun=0;


if(!@ARGV[1])
{
	print "Please specify 'daily' or 'weekly'\n";
	exit;
}
our $frequency = @ARGV[1];

if(! -e $xmlconf)
{
	print "I could not find the xml config file: $xmlconf\nYou can specify the path when executing this script\n";
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
	our $domainname;
	our $fromDate='';
	our $fromDateObject='';
	our $toDate='';
  
 if($conf)
 {
	%conf = %{$conf};
	if($conf{"queryfile"})
	{
		my $queries = $mobUtil->readQueryFile($conf{"queryfile"});
		if($queries)
		{
			%queries = %{$queries};
		}
		else
		{
			print "Please provide a queryfile stanza in the config file\n";
			exit;
		}
	}
	else
	{
		print "Please provide a queryfile stanza in the config file\n";
		exit;	
	}
	$audio_book_score_when_audiobooks_dont_belong = $conf{"audio_book_score_when_audiobooks_dont_belong"};
	$electronic_score_when_bib_is_considered_electronic = $conf{"electronic_score_when_bib_is_considered_electronic"};
	#print "electronic_score_when_bib_is_considered_electronic = $electronic_score_when_bib_is_considered_electronic\n";
	#print "audio_book_score_when_audiobooks_dont_belong = $audio_book_score_when_audiobooks_dont_belong\n";
	@electronicSearchPhrases = $conf{"electronicsearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"electronicsearchphrases"})} : ();
	@audioBookSearchPhrases = $conf{"audiobooksearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"audiobooksearchphrases"})} : ();
	@microficheSearchPhrases = $conf{"microfichesearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"microfichesearchphrases"})} : ();
	@microfilmSearchPhrases = $conf{"microfilmsearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"microfilmsearchphrases"})} : ();
	@videoSearchPhrases = $conf{"videosearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"videosearchphrases"})} : ();
	@largePrintBookSearchPhrases = $conf{"largeprintbooksearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"largeprintbooksearchphrases"})} : ();
	@musicSearchPhrases = $conf{"musicsearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"musicsearchphrases"})} : ();
	@playawaySearchPhrases = $conf{"playawaysearchphrases"} ? @{$mobUtil->makeArrayFromComma($conf{"playawaysearchphrases"})} : ();
	
	if ($conf{"logfile"})
	{
		my $dt = DateTime->now(time_zone => "local"); 
		my $fdate = $dt->ymd;
		my $ftime = $dt->hms;
		my $dateString = "$fdate $ftime";
		my $subtractDays = 2;
		if($frequency eq 'weekly')
		{
			$subtractDays = 9; # The dates are whole days. When using greater than, you want to compare to the day before.
		}
		$fromDate = DateTime->now(time_zone => "local");  
		my $reportFromDate = DateTime->now(time_zone => "local");
		my $reportToDate = DateTime->now(time_zone => "local");
		$fromDate = $fromDate->subtract(days=>$subtractDays);
		$fromDateObject = $fromDate;
		$fromDate = $fromDate->ymd;
		$reportFromDate = $reportFromDate->subtract(days=>$subtractDays);
		$reportFromDate = $reportFromDate->add(days=>1);
		$reportFromDate = $reportFromDate->mdy;
		$toDate =  DateTime->now(time_zone => "local");
		$toDate = $toDate->ymd;
		$reportToDate = $reportToDate->add(days=>-1);
		$reportToDate = $reportToDate->mdy;
		$log = new Loghandler($conf->{"logfile"});
		$log->truncFile("");
		$log->addLogLine(" ---------------- Script Starting ---------------- ");
		print "Executing job  tail the log for information (".$conf{"logfile"}.")\n";
		my @reqs = ("logfile","tempdir","domainname","playawaysearchphrases","musicsearchphrases","largeprintbooksearchphrases","videosearchphrases","microfilmsearchphrases","microfichesearchphrases","audiobooksearchphrases","electronicsearchphrases"); 
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
			$domainname = lc($conf{"domainname"});
			$baseTemp =~ s/\/$//;
			$baseTemp.='/';
			$domainname =~ s/\/$//;
			$domainname =~ s/^http:\/\///;
			$domainname.='/';
			$domainname = 'http://'.$domainname;
			
			my $afterProcess = DateTime->now(time_zone => "local");
			my $difference = $afterProcess - $dt;
			my $format = DateTime::Format::Duration->new(pattern => '%M:%S');
			my $duration =  $format->format_duration($difference);
			my @tolist = ($conf{"alwaysemail"});
			if(length($errorMessage)==0) #none of the code currently sets an errorMessage but maybe someday
			{
				my $email = new email($conf{"fromemail"},\@tolist,$valid,1,\%conf);
				my @reports = @{reportResults()};
				my @attachments = (@{@reports[1]}, @seekdestroyReportFiles);
				my $reports = @reports[0];
				$frequency = uc$frequency;
				$email->sendWithAttachments("Catalog fix progress - $frequency $reportFromDate to $reportToDate","$reports\r\n\r\n-Evergreen Perl Squad-",\@attachments);
				foreach(@attachments)
				{
					unlink $_ or warn "Could not remove $_\n";
				}
				
			}
			elsif(length($errorMessage)>0)
			{
				my @tolist = ($conf{"alwaysemail"});
				my $email = new email($conf{"fromemail"},\@tolist,1,0,\%conf);
				$email->send("Evergreen Utility - Catalog Audit Job # $jobid - ERROR","$errorMessage\r\n\r\n-Evergreen Perl Squad-");
			}
			updateJob("Completed","");
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
	my $nine02s='';
	my $catedits='';
	my $cateditsDailyBreakdown='';
	my @attachments=();
	
	
	my $query = "
	select split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"a\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"b\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"c\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"d\">\$\$,2),\$\$<\$\$,1),count(*)
from biblio.record_entry bre where bre.marc ~ \$\$<datafield tag=\"902\"\$\$
and
lower(split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"a\">\$\$,2),\$\$<\$\$,1))~'mz7a'
and
lower(split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"b\">\$\$,2),\$\$<\$\$,1))::date > '$fromDate'::date
and
lower(split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"b\">\$\$,2),\$\$<\$\$,1))::date < '$toDate'::date
group by split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"a\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"b\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"c\">\$\$,2),\$\$<\$\$,1),
split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"d\">\$\$,2),\$\$<\$\$,1)
order by lower(split_part(split_part(split_part(marc,\$\$<datafield tag=\"902\"\$\$,2),\$\$<subfield code=\"b\">\$\$,2),\$\$<\$\$,1))::date";
$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],9);
		$line = $mobUtil->insertDataIntoColumn($line,@row[2],23);
		$line = $mobUtil->insertDataIntoColumn($line,@row[3],38);
		$line = $mobUtil->insertDataIntoColumn($line,@row[4],58);
		$nine02s.="$line\r\n";
		$count+=@row[4];
	}
	if($count>0)
	{
		my $headerForEmail = "902a";
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"902b",9);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"902c",23);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"902d",38);
		$headerForEmail = $mobUtil->insertDataIntoColumn($headerForEmail,"# of occurrences",58);
		$nine02s = $headerForEmail."\r\n$nine02s";
		$nine02s="Summary 902\r\nTotal: $count\r\n$nine02s\r\n\r\n";
		$nine02s = truncateOutput($nine02s,7000);
		my @header = ("902a","902b","902c","902d","# of occurrences");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."902_summary.csv");
		push(@attachments,$baseTemp."902_summary.csv");
	}
	
	
	$fromDateObject = $fromDateObject->add(days=>1);
	$fromDate =$fromDateObject->ymd;
	my $query = "
	select to_char(edit_date, 'Day'),count(*)
	from biblio.record_entry where edit_date > '$fromDate'::date and edit_date < '$toDate'::date and editor=242420
	group by to_char(edit_date, 'Day') order by count";
	$log->addLine($query);
	my @results = @{$dbHandler->query($query)};
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		$count+=@row[1];
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$cateditsDailyBreakdown.="$line\r\n";
	}
	if($count>0)
	{
		$cateditsDailyBreakdown="Daily Breakdown: edited by contractcat\r\nDay Of The Week, Count\r\n$cateditsDailyBreakdown\r\n\r\n";
		$cateditsDailyBreakdown = truncateOutput($cateditsDailyBreakdown,8000);
	}
	
	
	my $query = "
	select id,
\$\$$domainname"."eg/opac/record/\$\$||id||\$\$?expand=marchtml\$\$,to_char(edit_date, 'MM/DD/YY HH12:MI AM')
	from biblio.record_entry where edit_date > '$fromDate'::date and edit_date < '$toDate'::date and editor=242420
	order by edit_date";
	$log->addLine($query);
	my @results = @{$dbHandler->query($query)};
	my $count=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		$count++;
		my $line = @row[0];		
		$line = $mobUtil->insertDataIntoColumn($line,@row[1],11);
		$line = $mobUtil->insertDataIntoColumn($line," ".@row[2],80);
		$catedits.="$line\r\n";
	}
	if($count>0)
	{
		$catedits="$count Records edited by contractcat\r\n$catedits\r\n\r\n";
		$catedits = truncateOutput($catedits,8000);
		my @header = ("BIB ID","OPAC LINK","Edit Date");
		my @outputs = ([@header],@results);
		createCSVFileFrom2DArray(\@outputs,$baseTemp."Bibs_touched_by_contractcat.csv");
		push(@attachments,$baseTemp."Bibs_touched_by_contractcat.csv");
	}
	
	
	my $ret=$nine02s."\r\n\r\n".$cateditsDailyBreakdown.$catedits."\r\n\r\nPlease see attached spreadsheets for full details";
	#print $ret;
	my @returns = ($ret,\@attachments);
	return \@returns;
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

sub tag902s
{
	my $query = "
		select record,extra,(select marc from biblio.record_entry where id=a.record) from SEEKDESTROY.BIB_MARC_UPDATE a";
 
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $reason = @row[1];
		my $marc = @row[2];
		my $note = '';
		if($reason eq "Correcting for DVD in the leader/007 rem 008_23")
		{
			$note='D V D';
		}
		elsif($reason eq "Correcting for Audiobook in the leader/007 rem 008_23")
		{
			$note='A u d i o b o o k';
		}
		elsif($reason eq "Correcting for Electronic in the 008/006")
		{
			$note='E l e c t r o n i c';
		}
		else
		{
			print "Skipping $bibid\n";
			next;
		}
		my $xmlresult = $marc;
		$xmlresult =~ s/(<leader>.........)./${1}a/;
		#$log->addLine($xmlresult);
		my $check = length($xmlresult);
		#$log->addLine($check);
		$xmlresult = fingerprintScriptMARC($xmlresult,$note);
		$xmlresult =~s/<record>//;
		$xmlresult =~s/<\/record>//;
		$xmlresult =~s/<\/collection>/<\/record>/;
		$xmlresult =~s/<collection/<record  /;
		$xmlresult =~s/XMLSchema-instance"/XMLSchema-instance\"  /;
		$xmlresult =~s/schema\/MARC21slim.xsd"/schema\/MARC21slim.xsd\"  /;
		
		#$log->addLine($xmlresult);
		#$log->addLine(length($xmlresult));
		if(length($xmlresult)!=$check)
		{		
			updateMARC($xmlresult,$bibid,'false',"Tagging 902 for $note");
		}
		else
		{
			print "Skipping $bibid - Already had the 902 for $note\n";
		}
	}
}

sub findInvalid856TOCURL
{
	my $query = "
select id,marc from biblio.record_entry where not deleted and 
lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\"><subfield code=\"3\">table of contents.+?</datafield>\$\$
or
lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\"><subfield code=\"3\">publisher description.+?</datafield>\$\$
	";
 
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $id = @row[0];
		my $marc = @row[1];
		if(!isScored( $id))
		{
			my @scorethis = ($id,$marc);
			my @st = ([@scorethis]);			
			updateScoreCache(\@st);
		}
		$query="INSERT INTO SEEKDESTROY.PROBLEM_BIBS(RECORD,PROBLEM,JOB) VALUES (\$1,\$2,\$3)";
		my @values = ($id,"MARC with table of contents E-Links",$jobid);
		$dbHandler->updateWithParameters($query,\@values);
	}
}

sub setMARCForm
{
	my $marc = @_[0];
	my $char = @_[1];
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my $marcr = populate_marc($marcob);	
	my %marcr = %{normalize_marc($marcr)};    
	my $replacement;
	my $altered=0;
	if($marcr{tag008})
	{
		my $z08 = $marcob->field('008');
		$marcob->delete_field($z08);
		#print "$marcr{tag008}\n";
		$replacement=$mobUtil->insertDataIntoColumn($marcr{tag008},$char,24);
		#print "$replacement\n";
		$z08->update($replacement);
		$marcob->insert_fields_ordered($z08);
		$altered=1;
	}
	elsif($marcr{tag006})
	{
		my $z06 = $marcob->field('006');
		$marcob->delete_fields($z06);
		#print "$marcr{tag006}\n";
		$replacement=$mobUtil->insertDataIntoColumn($marcr{tag006},$char,7);
		#print "$replacement\n";
		$z06->update($replacement);
		$marcob->insert_fields_ordered($z06);
		$altered=1;
	}
	if(!$altered && $char ne ' ')
	{
		$replacement=$mobUtil->insertDataIntoColumn("",$char,24);
		$replacement=$mobUtil->insertDataIntoColumn($replacement,' ',39);
		my $z08 = MARC::Field->new( '008', $replacement );
		#print "inserted new 008\n".$z08->data()."\n";
		$marcob->insert_fields_ordered($z08);
	}
	
	my $xmlresult = convertMARCtoXML($marcob);
	return $xmlresult;
}

sub updateMARCSetElectronic
{	
	my $bibid = @_[0];
	my $marc = @_[1];
	$marc = setMARCForm($marc,'s');
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my $marcr = populate_marc($marcob);	
	my %marcr = %{normalize_marc($marcr)};
	my $xmlresult = convertMARCtoXML($marcob);	
	$xmlresult = fingerprintScriptMARC($xmlresult,'E l e c t r o n i c');
	updateMARC($xmlresult,$bibid,'false','Correcting for Electronic in the 008/006');
}

sub updateMARCSetCDAudioBook
{	
	my $bibid = @_[0];
	my $marc = @_[1];
	$marc = setMARCForm($marc,' ');
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my $marcr = populate_marc($marcob);	
	my %marcr = %{normalize_marc($marcr)};    
	my $replacement;
	my $altered=0;
	foreach(@{$marcr{tag007}})
	{		
		if(substr($_->data(),0,1) eq 's')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
			#print $z07->data()."\n";
			$replacement=$mobUtil->insertDataIntoColumn($z07->data(),'s',1);
			$replacement=$mobUtil->insertDataIntoColumn($replacement,'f',4);
			#print "$replacement\n";			
			$z07->update($replacement);
			$marcob->insert_fields_ordered($z07);
			$altered=1;
		}
		elsif(substr($_->data(),0,1) eq 'v')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
			#print "removed video 007\n";
		}
	}
	if(!$altered)
	{
		my $z07 = MARC::Field->new( '007', 'sd fsngnnmmned' );
		#print "inserted new 007\n".$z07->data()."\n";
		$marcob->insert_fields_ordered($z07);
	}
	my $xmlresult = convertMARCtoXML($marcob);
	$xmlresult = fingerprintScriptMARC($xmlresult,'A u d i o b o o k');
	$xmlresult = updateMARCSetSpecifiedLeaderByte($bibid,$xmlresult,7,'i');
	updateMARC($xmlresult,$bibid,'false','Correcting for Audiobook in the leader/007 rem 008_23');
}

sub updateMARCSetDVD
{	
	my $bibid = @_[0];
	print "updating marc for $bibid\n";
	my $marc = @_[1];
	$marc = setMARCForm($marc,' ');
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my $marcr = populate_marc($marcob);	
	my %marcr = %{normalize_marc($marcr)};    
	my $replacement;
	my $altered=0;
	foreach(@{$marcr{tag007}})
	{		
		if(substr($_->data(),0,1) eq 'v')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
			#print $z07->data()."\n";
			$replacement=$mobUtil->insertDataIntoColumn($z07->data(),'v',1);
			$replacement=$mobUtil->insertDataIntoColumn($replacement,'v',5);
			#print "$replacement\n";			
			$z07->update($replacement);
			$marcob->insert_fields_ordered($z07);
			$altered=1;
		}
		elsif(substr($_->data(),0,1) eq 's')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
			#print "removed video 007\n";
		}
	}
	if(!$altered)
	{
		my $z07 = MARC::Field->new( '007', 'vd cvaizq' );
		#print "inserted new 007\n".$z07->data()."\n";
		$marcob->insert_fields_ordered($z07);
	}
	my $xmlresult = convertMARCtoXML($marcob);
	$xmlresult = fingerprintScriptMARC($xmlresult,'D V D');
	$xmlresult = updateMARCSetSpecifiedLeaderByte($bibid,$xmlresult,7,'g');
	updateMARC($xmlresult,$bibid,'false','Correcting for DVD in the leader/007 rem 008_23');
}

sub updateMARCSetLargePrint
{	
	my $bibid = @_[0];
	print "updating marc for $bibid\n";
	my $marc = @_[1];
	$marc = setMARCForm($marc,'d');
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my $marcr = populate_marc($marcob);	
	my %marcr = %{normalize_marc($marcr)};    
	foreach(@{$marcr{tag007}})
	{		
		if(substr($_->data(),0,1) eq 'v')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
		}
		elsif(substr($_->data(),0,1) eq 's')
		{
			my $z07 = $_;
			$marcob->delete_field($z07);
		}
	}
	my $xmlresult = convertMARCtoXML($marcob);
	$xmlresult = fingerprintScriptMARC($xmlresult,'L a r g e P r i n t');
	$xmlresult = updateMARCSetSpecifiedLeaderByte($bibid,$xmlresult,7,'a');
	updateMARC($xmlresult,$bibid,'false','Correcting for Large Print in the leader/007 rem 008_23');
}

sub fingerprintScriptMARC
{
	my $marc = @_[0];
	my $note = @_[1];
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);
	my @n902 = $marcob->field('902');
	my $altered = 0;
	my $dt = DateTime->now(time_zone => "local"); 
	my $fdate = $dt->mdy; 
	foreach(@n902)
	{
		my $field = $_;
		my $suba = $field->subfield('a');
		my $subd = $field->subfield('d');
		if($suba && $suba eq 'mobius-catalog-fix' && $subd && $subd eq "$note")
		{
			#print "Found a matching 902 for $note - updating that one\n";
			$altered = 1;
			my $new902 = MARC::Field->new( '902',' ',' ','a'=>'mobius-catalog-fix','b'=>"$fdate",'c'=>'formatted','d'=>"$note" );
			$marcob->delete_field($field);
			$marcob->append_fields($new902);
		}
	}
	if(!$altered)
	{
		my $new902 = MARC::Field->new( '902',' ',' ','a'=>'mobius-catalog-fix','b'=>"$fdate",'c'=>'formatted','d'=>"$note" );
		$marcob->append_fields($new902);
	}
	my $xmlresult = convertMARCtoXML($marcob);
	return $xmlresult
}

sub updateMARCSetSpecifiedLeaderByte  
{	
	my $bibid = @_[0];
	my $marc = @_[1];
	my $leaderByte = @_[2];		#1 based
	my $value = @_[3];
	my $marcob = $marc;
	$marcob =~ s/(<leader>.........)./${1}a/;
	$marcob = MARC::Record->new_from_xml($marcob);	
	my $leader = $marcob->leader();
	#print $leader."\n";
	$leader=$mobUtil->insertDataIntoColumn($leader,$value,$leaderByte);
	#print $leader."\n";
	$marcob->leader($leader);
	#print $marcob->leader()."\n";
	my $xmlresult = convertMARCtoXML($marcob);
	return $xmlresult;
}

sub updateMARC
{
	my $newmarc = @_[0];
	my $bibid = @_[1];
	my $newrecord = @_[2];
	my $extra = @_[3];
	my $query = "INSERT INTO SEEKDESTROY.BIB_MARC_UPDATE (RECORD,PREV_MARC,CHANGED_MARC,NEW_RECORD,EXTRA,JOB)
	VALUES(\$1,(SELECT MARC FROM BIBLIO.RECORD_ENTRY WHERE ID=\$2),\$3,\$4,\$5,\$6)";		
	my @values = ($bibid,$bibid,$newmarc,$newrecord,$extra,$jobid);
	$dbHandler->updateWithParameters($query,\@values);
	$query = "UPDATE BIBLIO.RECORD_ENTRY SET MARC=\$1 WHERE ID=\$2";
	updateJob("Processing","updateMARC $extra  $query");
	@values = ($newmarc,$bibid);
	$dbHandler->updateWithParameters($query,\@values);
}

sub findInvalidElectronicMARC
{
	$log->addLogLine("Starting findInvalidElectronicMARC.....");
	my $typeName = "electronic";
	my $problemPhrase = "MARC with E-Links but 008 tag is missing o,q,s";
	my $phraseQuery = $queries{"electronic_search_phrase"};
	my @additionalSearchQueries = ($queries{"electronic_additional_search"});
	my $subQueryConvert = $queries{"non_electronic_bib_convert_to_electronic"};
	my $subQueryNotConvert =  $queries{"non_electronic_bib_not_convert_to_electronic"};
	my $convertFunction = "updateMARCSetElectronic(\$id,\$marc);";	
	findInvalidMARC(
	$typeName,
	$problemPhrase,
	$phraseQuery,
	\@additionalSearchQueries,
	$subQueryConvert,
	$subQueryNotConvert,
	$convertFunction,
	\@electronicSearchPhrases
	);
}

sub findInvalidAudioBookMARC
{	
	$log->addLogLine("Starting findInvalidAudioBookMARC.....");
	my $typeName = "audiobook";
	my $problemPhrase = "MARC with audiobook phrases but incomplete marc";
	my $phraseQuery = $queries{"audiobook_search_phrase"};
	my @additionalSearchQueries = ($queries{"audiobook_additional_search"});
	my $subQueryConvert = $queries{"non_audiobook_bib_convert_to_audiobook"};
	my $subQueryNotConvert =  $queries{"non_audiobook_bib_not_convert_to_audiobook"};
	my $convertFunction = "updateMARCSetCDAudioBook(\$id,\$marc);";		
	findInvalidMARC(
	$typeName,
	$problemPhrase,
	$phraseQuery,
	\@additionalSearchQueries,
	$subQueryConvert,
	$subQueryNotConvert,
	$convertFunction,
	\@audioBookSearchPhrases
	);
}

sub findInvalidDVDMARC
{
	$log->addLogLine("Starting findInvalidDVDMARC.....");
	my $typeName = "video";
	my $problemPhrase = "MARC with video phrases but incomplete marc";
	my $phraseQuery = $queries{"non_dvd_bib_convert_to_dvd"};
	my @additionalSearchQueries = ($queries{"dvd_additional_search"});
	my $subQueryConvert = $queries{"non_dvd_bib_convert_to_dvd"};
	my $subQueryNotConvert =  $queries{"non_dvd_bib_not_convert_to_dvd"};
	my $convertFunction = "updateMARCSetDVD(\$id,\$marc);";
	findInvalidMARC(
	$typeName,
	$problemPhrase,
	$phraseQuery,
	\@additionalSearchQueries,
	$subQueryConvert,
	$subQueryNotConvert,
	$convertFunction,
	\@videoSearchPhrases
	);
}


sub findInvalidLargePrintMARC
{	
	$log->addLogLine("Starting findInvalidLargePrintMARC.....");
	my $typeName = "large_print";
	my $problemPhrase = "MARC with large_print phrases but incomplete marc";
	my $phraseQuery = $queries{"largeprint_search_phrase"};
	my @additionalSearchQueries = ();
	my $subQueryConvert = $queries{"non_large_print_bib_convert_to_large_print"};
	my $subQueryNotConvert =  $queries{"non_large_print_bib_not_convert_to_large_print"};
	my $convertFunction = "updateMARCSetLargePrint(\$id,\$marc);";	
	findInvalidMARC(
	$typeName,
	$problemPhrase,
	$phraseQuery,
	\@additionalSearchQueries,
	$subQueryConvert,
	$subQueryNotConvert,
	$convertFunction,
	\@largePrintBookSearchPhrases
	);
}


sub findInvalidMARC
{	
	my $typeName = @_[0];
	my $problemPhrase = @_[1];
	my $phraseQuery = @_[2];
	my @additionalSearchQueries = @{@_[3]};
	my $subQueryConvert = @_[4];
	my $subQueryNotConvert = @_[5];
	my $convertFunction = @_[6];
	my @marcSearchPhrases = @{@_[7]};
	
	
	my $query = "DELETE FROM SEEKDESTROY.PROBLEM_BIBS WHERE PROBLEM=\$\$$problemPhrase\$\$";
	$log->addLine($query);
	updateJob("Processing","findInvalidMARC  $query");
	#$dbHandler->update($query);
	foreach(@marcSearchPhrases)
	{
		my $phrase = lc$_;
		my $query = $phraseQuery;
		$query =~ s/\$phrase/$phrase/g;
		$query =~ s/\$problemphrase/$problemPhrase/g;
		$log->addLine($query);
		updateJob("Processing","findInvalidMARC  $query");
		updateProblemBibs($query,$problemPhrase,$typeName);
	}
	foreach(@additionalSearchQueries)
	{
		my $query = $_;				
		$query =~ s/\$problemphrase/$problemPhrase/g;
		$log->addLine($query);
		updateJob("Processing","findInvalidMARC  $query");
		updateProblemBibs($query,$problemPhrase,$typeName);
	}
	
	# Now that we have digested the possibilities - 
	# Lets weed them out into bibs that we want to convert	
	my $output='';
	my $toCSV = "";
	my $query = "select	
	(select deleted from biblio.record_entry where id= sbs.record),record,
 \$\$$domainname"."eg/opac/record/\$\$||record||\$\$?expand=marchtml\$\$,
 winning_score,
  opac_icon \"opac icon\",
 winning_score_score,winning_score_distance,second_place_score,
 circ_mods,call_labels,copy_locations,
 score,record_type,audioformat,videoformat,electronic,audiobook_score,music_score,playaway_score,largeprint_score,video_score,microfilm_score,microfiche_score,
 (select marc from biblio.record_entry where id=sbs.record)
  from seekdestroy.bib_score sbs where record in( $subQueryConvert )
  order by (select deleted from biblio.record_entry where id= sbs.record),winning_score,winning_score_distance,electronic,second_place_score,circ_mods,call_labels,copy_locations
";

	$log->addLine($query);
	my @results = @{$dbHandler->query($query)};
	my @convertList=@results;	
	foreach(@results)
	{
		my @row = @{$_};
		my $id = @row[1];
		my $marc = @row[23];
		my @line=@{$_};
		@line[23]='';
		$output.=$mobUtil->makeCommaFromArray(\@line,';')."\n";
		$toCSV.=$mobUtil->makeCommaFromArray(\@line,',')."\n";
		if(!$dryrun)
		{
			eval($convertFunction);
		}
	}
	
	my $header = "\"Deleted\",\"BIB ID\",\"OPAC Link\",\"Winning_score\",\"OPAC ICON\",\"Winning Score\",\"Winning Score Distance\",\"Second Place Score\",\"Circ Modifiers\",\"Call Numbers\",\"Locations\",\"Record Quality\",\"record_type\",\"audioformat\",\"videoformat\",\"electronic\",\"audiobook_score\",\"music_score\",\"playaway_score\",\"largeprint_score\",\"video_score\",\"microfilm_score\",\"microfiche_score\"";
	if(length($toCSV)>0)
	{
		my $csv = new Loghandler($baseTemp."Converted_".$typeName."_bibs.csv");
		$csv->addLine($header."\n".$toCSV);
		push(@seekdestroyReportFiles,$baseTemp."Converted_".$typeName."_bibs.csv");
	}
	$log->addLine("Will Convert these to $typeName: $#convertList\n\n\n");
	$log->addLine($output);
	@convertList=();
	
	my $query = "select	
	(select deleted from biblio.record_entry where id= sbs.record),record,
 \$\$$domainname"."eg/opac/record/\$\$||record||\$\$?expand=marchtml\$\$,
 winning_score,
  opac_icon \"opac icon\",
 winning_score_score,winning_score_distance,second_place_score,
 circ_mods,call_labels,copy_locations,
 score,record_type,audioformat,videoformat,electronic,audiobook_score,music_score,playaway_score,largeprint_score,video_score,microfilm_score,microfiche_score,
 (select marc from biblio.record_entry where id=sbs.record)
  from seekdestroy.bib_score sbs where record in( $subQueryNotConvert )
  order by (select deleted from biblio.record_entry where id= sbs.record),winning_score,winning_score_distance,electronic,second_place_score,circ_mods,call_labels,copy_locations
";

	$log->addLine($query);
	my @results = @{$dbHandler->query($query)};
	my @convertList=@results;	
	$log->addLine("Will NOT Convert these (Need Humans): $#convertList\n\n\n");
	$output='';
	$toCSV='';
	foreach(@convertList)
	{
		my @line=@{$_};
		$output.=$mobUtil->makeCommaFromArray(\@line,';')."\n";
		$toCSV.=$mobUtil->makeCommaFromArray(\@line,',')."\n";
	}	
	my $header = "\"Deleted\",\"BIB ID\",\"OPAC Link\",\"Winning_score\",\"OPAC ICON\",\"Winning Score\",\"Winning Score Distance\",\"Second Place Score\",\"Circ Modifiers\",\"Call Numbers\",\"Locations\",\"Record Quality\",\"record_type\",\"audioformat\",\"videoformat\",\"electronic\",\"audiobook_score\",\"music_score\",\"playaway_score\",\"largeprint_score\",\"video_score\",\"microfilm_score\",\"microfiche_score\"";
	if(length($toCSV)>0)
	{
		my $csv = new Loghandler($baseTemp."Need_Humans_".$typeName."_bibs.csv");
		$csv->addLine($header."\n".$toCSV);
		push(@seekdestroyReportFiles,$baseTemp."Need_Humans_".$typeName."_bibs.csv");
	}
	$log->addLine($output);
@convertList=();
	
}

sub updateProblemBibs
{
	my $query = @_[0];
	my $problemphrase = @_[1];
	my $typeName = @_[2];
	my @results = @{$dbHandler->query($query)};		
	$log->addLine(($#results+1)." possible invalid $typeName MARC\n\n\n");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $id = @row[0];
		my $marc = @row[1];

		my @scorethis = ($id,$marc);
		my @st = ([@scorethis]);			
		updateScoreCache(\@st);

		$query="INSERT INTO SEEKDESTROY.PROBLEM_BIBS(RECORD,PROBLEM,JOB) VALUES (\$1,\$2,\$3)";
		my @values = ($id,$problemphrase,$jobid);
		$dbHandler->updateWithParameters($query,\@values);
	}
}



sub isScored
{	
	my $bibid = @_[0];
	my $query = "SELECT ID FROM SEEKDESTROY.BIB_SCORE WHERE RECORD = $bibid";
	my @results = @{$dbHandler->query($query)};
	if($#results>-1)
	{
		return 1;
	}
	return 0;
}

sub updateScoreCache
{
	my @newIDs;
	my @newAndUpdates;
	my @updateIDs;
	if(@_[0])
	{	
		@newIDs=@{@_[0]};
	}
	else
	{
		@newAndUpdates = @{identifyBibsToScore($dbHandler)};
		@newIDs = @{@newAndUpdates[0]};
	}
	##print Dumper(@newIDs);
	#$log->addLine("Found ".($#newIDs+1)." new Bibs to be scored");	
	if(@newAndUpdates[1])
	{
		@updateIDs = @{@newAndUpdates[1]};
		#$log->addLine("Found ".($#updateIDs+1)." new Bibs to update score");	
	}
	foreach(@newIDs)
	{
		my @thisone = @{$_};
		my $bibid = @thisone[0];		
		my $marc = @thisone[1];
		#$log->addLine("bibid = $bibid");
		#print "bibid = $bibid";
		#print "marc = $marc";
		my $query = "DELETE FROM SEEKDESTROY.BIB_SCORE WHERE RECORD = $bibid";
		$dbHandler->update($query);
		my $marcob = $marc;
		$marcob =~ s/(<leader>.........)./${1}a/;
		$marcob = MARC::Record->new_from_xml($marcob);
		my $score = scoreMARC($marcob);
		my %allscores = %{getAllScores($marcob)};
		my %fingerprints = %{getFingerprints($marcob)};
		#$log->addLine(Dumper(%fingerprints));
		my $query = "INSERT INTO SEEKDESTROY.BIB_SCORE
		(RECORD,
		SCORE,
		ELECTRONIC,
		audiobook_score,
		largeprint_score,
		video_score,
		microfilm_score,
		microfiche_score,
		music_score,
		playaway_score,
		winning_score,
		winning_score_score,
		winning_score_distance,
		second_place_score,
		item_form,
		date1,
		record_type,
		bib_lvl,
		title,
		author,
		sd_fingerprint,
		audioformat,
		videoformat,
		eg_fingerprint) 
		VALUES($bibid,$score,
		$allscores{'electricScore'},
		$allscores{'audioBookScore'},
		$allscores{'largeprint_score'},
		$allscores{'video_score'},
		$allscores{'microfilm_score'},
		$allscores{'microfiche_score'},
		$allscores{'music_score'},
		$allscores{'playaway_score'},
		'$allscores{'winning_score'}',
		$allscores{'winning_score_score'},
		$allscores{'winning_score_distance'},
		'$allscores{'second_place_score'}',
		\$1,\$2,\$3,\$4,\$5,\$6,\$7,\$8,\$9,(SELECT FINGERPRINT FROM BIBLIO.RECORD_ENTRY WHERE ID=$bibid)
		)";		
		my @values = (
		$fingerprints{item_form},
		$fingerprints{date1},
		$fingerprints{record_type},
		$fingerprints{bib_lvl},
		$fingerprints{title},
		$fingerprints{author},
		$fingerprints{baseline},
		$fingerprints{audioformat},
		$fingerprints{videoformat}
		);		
		$dbHandler->updateWithParameters($query,\@values);
		updateBibCircsScore($bibid,$dbHandler);
		updateBibCallLabelsScore($bibid);
		updateBibCopyLocationsScore($bibid);		
	}
	foreach(@updateIDs)
	{
		my @thisone = @{$_};
		my $bibid = @thisone[0];
		my $marc = @thisone[1];
		my $bibscoreid = @thisone[2];
		my $oldscore = @thisone[3];
		my $marcob = $marc;
		$marcob =~ s/(<leader>.........)./${1}a/;
		$marcob = MARC::Record->new_from_xml($marcob);		
		my $score = scoreMARC($marcob);		
		my %allscores = %{getAllScores($marcob)};
		my %fingerprints = %{getFingerprints($marcob)};		
		my $improved = $score - $oldscore;
		my $query = "UPDATE SEEKDESTROY.BIB_SCORE SET IMPROVED_SCORE_AMOUNT = $improved, SCORE = $score, SCORE_TIME=NOW(), 
		ELECTRONIC=$allscores{'electricScore'},
		audiobook_score=$allscores{'audioBookScore'},
		largeprint_score=$allscores{'largeprint_score'},
		video_score=$allscores{'video_score'},
		microfilm_score=$allscores{'microfilm_score'},
		microfiche_score=$allscores{'microfiche_score'},
		music_score=$allscores{'music_score'},
		playaway_score=$allscores{'playaway_score'},
		winning_score='$allscores{'winning_score'}',
		winning_score_score=$allscores{'winning_score_score'},
		winning_score_distance=$allscores{'winning_score_distance'},
		second_place_score='$allscores{'second_place_score'}',
		item_form = \$1,
		date1 = \$2,
		record_type = \$3,
		bib_lvl = \$4,
		title = \$5,
		author = \$6,
		sd_fingerprint = \$7,
		audioformat = \$8,
		audioformat = \$9,
		eg_fingerprint = (SELECT FINGERPRINT FROM BIBLIO.RECORD_ENTRY WHERE ID=$bibid)
		WHERE ID=$bibscoreid";
		my @values = (
		$fingerprints{item_form},
		$fingerprints{date1},
		$fingerprints{record_type},
		$fingerprints{bib_lvl},
		$fingerprints{title},
		$fingerprints{author},
		$fingerprints{baseline},
		$fingerprints{audioformat},
		$fingerprints{videoformat}
		);
		$dbHandler->updateWithParameters($query,\@values);
		updateBibCircsScore($bibid);
		updateBibCallLabelsScore($bibid);
		updateBibCopyLocationsScore($bibid);
	}
}

sub updateBibCircsScore
{	
	my $bibid = @_[0];	
	my $query = "DELETE FROM seekdestroy.bib_item_circ_mods WHERE RECORD=$bibid";
	$dbHandler->update($query);
	
	$query = "
	select ac.circ_modifier,acn.record  from asset.copy ac,asset.call_number acn,biblio.record_entry bre where
	acn.id=ac.call_number and
	bre.id=acn.record and
	acn.record = $bibid and
	not acn.deleted and
	not bre.deleted and
	not ac.deleted
	group by ac.circ_modifier,acn.record
	order by record";
	my $allcircs='';
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $circmod = @row[0];
		my $record = @row[1];
		my $q="INSERT INTO seekdestroy.bib_item_circ_mods(record,circ_modifier,different_circs,job)
		values
		(\$1,\$2,\$3,\$4)";
		my @values = ($record,$circmod,$#results+1,$jobid);
		$allcircs.=$circmod.',';
		$dbHandler->updateWithParameters($q,\@values);
	}
	$allcircs=substr($allcircs,0,-1);
	my $opacicons='';
	# get opac icon string
	$query = "select string_agg(value,',') from metabib.record_attr_flat where attr='icon_format' and id=$bibid";
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		$opacicons = @row[0];
	}
	$query = "UPDATE SEEKDESTROY.BIB_SCORE SET OPAC_ICON=\$1,CIRC_MODS=\$2 WHERE RECORD=$bibid";
	my @values = ($opacicons,$allcircs);
	$dbHandler->updateWithParameters($query,\@values);
	
}

sub updateBibCallLabelsScore
{	
	my $bibid = @_[0];	
	my $query = "DELETE FROM seekdestroy.bib_item_call_labels WHERE RECORD=$bibid";
	$dbHandler->update($query);
	
	$query = "
	select 
	(select label from asset.call_number_prefix where id=acn.prefix)||acn.label||(select label from asset.call_number_suffix where id=acn.suffix),acn.record
	from asset.copy ac,asset.call_number acn,biblio.record_entry bre where
	acn.id=ac.call_number and
	bre.id=acn.record and
	acn.record = $bibid and
	not acn.deleted and
	not bre.deleted and
	not ac.deleted
	group by (select label from asset.call_number_prefix where id=acn.prefix)||acn.label||(select label from asset.call_number_suffix where id=acn.suffix),acn.record
	order by record";
	my $allcalls='';
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $calllabel = @row[0];
		my $record = @row[1];
		my $q="INSERT INTO seekdestroy.bib_item_call_labels(record,call_label,different_call_labels,job)
		values
		(\$1,\$2,\$3,\$4)";
		my @values = ($record,$calllabel,$#results+1,$jobid);
		$allcalls.=$calllabel.',';
		$dbHandler->updateWithParameters($q,\@values);
	}
	$allcalls=substr($allcalls,0,-1);
	
	$query = "UPDATE SEEKDESTROY.BIB_SCORE SET CALL_LABELS=\$1 WHERE RECORD=$bibid";
	my @values = ($allcalls);
	$dbHandler->updateWithParameters($query,\@values);
}

sub updateBibCopyLocationsScore
{	
	my $bibid = @_[0];	
	my $query = "DELETE FROM seekdestroy.bib_item_locations WHERE RECORD=$bibid";
	$dbHandler->update($query);
	
	$query = "
	select 
	acl.name,acn.record
	from asset.copy ac,asset.call_number acn,biblio.record_entry bre,asset.copy_location acl where
	acl.id=ac.location and
	acn.id=ac.call_number and
	bre.id=acn.record and
	acn.record = $bibid and
	not acn.deleted and
	not bre.deleted and
	not ac.deleted
	group by acl.name,acn.record
	order by record";
	my $alllocs='';
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $location = @row[0];
		my $record = @row[1];
		my $q="INSERT INTO seekdestroy.bib_item_locations(record,location,different_locations,job)
		values
		(\$1,\$2,\$3,\$4)";
		my @values = ($record,$location,$#results+1,$jobid);
		$alllocs.=$location.',';
		$dbHandler->updateWithParameters($q,\@values);
	}
	$alllocs=substr($alllocs,0,-1);
	
	$query = "UPDATE SEEKDESTROY.BIB_SCORE SET COPY_LOCATIONS=\$1 WHERE RECORD=$bibid";
	my @values = ($alllocs);
	$dbHandler->updateWithParameters($query,\@values);
}

sub findPhysicalItemsOnElectronicBooksUnDedupe
{
	# Find Electronic bibs with physical items and in the dedupe project
	
	my $query = "
	select id,marc from biblio.record_entry where not deleted and lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\">\$\$
	and id in
	(
	select record from asset.call_number where not deleted and id in(select call_number from asset.copy where not deleted)
	)
	and id in
	(select lead_bibid from m_dedupe.merge_map)
	and 
	(
		marc ~ \$\$tag=\"008\">.......................[oqs]\$\$
		or
		marc ~ \$\$tag=\"006\">......[oqs]\$\$
	)
	and
	(
		marc ~ \$\$<leader>......[at]\$\$
	)
	and
	(
		marc ~ \$\$<leader>.......[acdm]\$\$
	)
	";
	updateJob("Processing","findPhysicalItemsOnElectronicBooksUnDedupe  $query");
	my @results = @{$dbHandler->query($query)};
	$log->addLine(($#results+1)." Bibs with physical Items attached from the dedupe");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $marc = @row[1];
		my @scorethis = ($bibid,$marc);
		my @st = ([@scorethis]);		
		updateScoreCache(\@st);
		recordAssetCopyMove($bibid);		
	}
}

sub getBibScores
{
	my $bib = @_[0];
	my $scoreType = @_[1];
	my $query = "SELECT $scoreType FROM SEEKDESTROY.BIB_SCORE WHERE RECORD=$bib";
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		return @row[0];
	}
	return -1;
}

sub addBibMatch
{
	my %queries = %{@_[0]};	
	my $matchedSomething=0;
	my $searchQuery = $queries{'searchQuery'};
	my $problem = $queries{'problem'};
	my @matchQueries = @{$queries{'matchQueries'}};
	my @takeActionWithTheseMatchingMethods = @{$queries{'takeActionWithTheseMatchingMethods'}};	
	updateJob("Processing","addBibMatch  $searchQuery");
	my @results = @{$dbHandler->query($searchQuery)};
	#$log->addLine(($#results+1)." Search Query results");
	foreach(@results)
	{
		my $matchedSomethingThisRound=0;
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $bibAudioScore = getBibScores($bibid,'audiobook_score');
		my $marc = @row[1];
		my $extra = @row[2] ? @row[2] : '';
		my @scorethis = ($bibid,$marc);
		my @st = ([@scorethis]);		
		updateScoreCache(\@st);
		my $query="INSERT INTO SEEKDESTROY.PROBLEM_BIBS(RECORD,PROBLEM,EXTRA,JOB) VALUES (\$1,\$2,\$3,\$4)";
		updateJob("Processing","addBibMatch  $query");
		my @values = ($bibid,$problem,$extra,$jobid);
		$dbHandler->updateWithParameters($query,\@values);
		## Now find likely candidates elsewhere in the ME DB	
		addRelatedBibScores($bibid);
		## Now run match queries starting with tight and moving down to loose
		my $i=0;
		while(!$matchedSomethingThisRound && @matchQueries[$i])
		{
			my $matchQ = @matchQueries[$i];
			$matchQ =~ s/\$bibid/$bibid/gi;
			my $matchReason = @matchQueries[$i+1];
			$i+=2;
			#$log->addLine($matchQ);
			updateJob("Processing","addBibMatch  $matchQ");
			my @results2 = @{$dbHandler->query($matchQ)};
			my $foundResults=0;
			foreach(@results2)
			{
				my @ro = @{$_};
				my $mbibid=@ro[0];
				my $holds = findHoldsOnBib($mbibid,$dbHandler);
				$query = "INSERT INTO SEEKDESTROY.BIB_MATCH(BIB1,BIB2,MATCH_REASON,HAS_HOLDS,JOB)
				VALUES(\$1,\$2,\$3,\$4,\$5)";
				updateJob("Processing","addBibMatch  $query");
				$log->addLine("Possible $bibid match: $mbibid $matchReason");
				my @values = ($bibid,$mbibid,$matchReason,$holds,$jobid);
				$dbHandler->updateWithParameters($query,\@values);
				$matchedSomething = 1;
				$matchedSomethingThisRound = 1;				
				$foundResults = 1;
			}
			if($foundResults)
			{
				my $tookAction=0;
				foreach(@takeActionWithTheseMatchingMethods)
				{
					if($_ eq $matchReason)
					{
						if($queries{'action'} eq 'moveallcopies')
						{
							$tookAction = moveCopiesOntoHighestScoringBibCandidate($bibid,$matchReason);
						}
						elsif($queries{'action'} eq 'movesomecopies')
						{
							if($queries{'ifaudioscorebelow'})
							{
								if( $bibAudioScore < $queries{'ifaudioscorebelow'} )
								{
									$tookAction = moveCopiesOntoHighestScoringBibCandidate($bibid,$matchReason,$extra);
								}
							}
							elsif($queries{'ifaudioscoreabove'})
							{
								if( $bibAudioScore > $queries{'ifaudioscoreabove'} )
								{
									$tookAction = moveCopiesOntoHighestScoringBibCandidate($bibid,$matchReason,$extra);
								}
							}

						}
						elsif($queries{'action'} eq 'mergebibs')
						{
							
						}
					}
				}
			}
		}		
	}
	return $matchedSomething;
}

sub addRelatedBibScores
{
	my $rootbib = @_[0];
	# Score bibs that have the same evergreen fingerprint
	my $query =
	"SELECT ID,MARC FROM BIBLIO.RECORD_ENTRY WHERE FINGERPRINT = (SELECT EG_FINGERPRINT FROM SEEKDESTROY.BIB_SCORE WHERE RECORD=$rootbib)";
	updateJob("Processing","addRelatedBibScores  $query");
	#$log->addLine($query);
	updateScoreWithQuery($query);
	
	# Pickup a few more bibs that contain the same title anywhere in the MARC
	# This is very slow and it doesn't help get real matches
	# This is disabled
	
	if(0)
	{
		$query="
		SELECT LOWER(TITLE) FROM SEEKDESTROY.BIB_SCORE WHERE RECORD=$rootbib";
		updateJob("Processing","addRelatedBibScores  $query");
		my @results = @{$dbHandler->query($query)};		
		foreach(@results)
		{
			my $row = $_;
			my @row = @{$row};
			my $title = @row[0];
			if(length($title)>5)
			{		
				$query =
				"SELECT ID,MARC FROM BIBLIO.RECORD_ENTRY WHERE LOWER(MARC) ~ (SELECT LOWER(TITLE) FROM SEEKDESTROY.BIB_SCORE WHERE RECORD=$rootbib)";
				updateJob("Processing","addRelatedBibScores  $query");
				$log->addLine($query);
				updateScoreWithQuery($query);
			}
		}
	}
	
}


sub attemptMovePhysicalItemsOnAnElectronicBook
{
	my $oldbib = @_[0];
	my $query;
	my %queries=();
	$queries{'action'} = 'moveallcopies';
	$queries{'problem'} = "Physical items attched to Electronic Bibs";
	my @okmatchingreasons=("Physical Items to Electronic Bib exact","Physical Items to Electronic Bib exact minus date1");
	$queries{'takeActionWithTheseMatchingMethods'}=\@okmatchingreasons;
	$queries{'searchQuery'} = "
	select id,marc from biblio.record_entry where not deleted and lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\">\$\$
	and id in
	(
	select record from asset.call_number where not deleted and id in(select call_number from asset.copy where not deleted)
	)	
	and 
	(
		marc ~ \$\$tag=\"008\">.......................[oqs]\$\$
		or
		marc ~ \$\$tag=\"006\">......[oqs]\$\$
	)
	and
	(
		marc ~ \$\$<leader>......[at]\$\$
	)
	and
	(
		marc ~ \$\$<leader>.......[acdm]\$\$
	)
	";	
	my @results;
	if($oldbib)
	{
		$queries{'searchQuery'} = "select id,marc from biblio.record_entry where id=$oldbib";
	}
	my @matchQueries = 
	(
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 
		DATE1 = (SELECT DATE1 FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Bib exact",
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 			
		RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Bib exact minus date1",
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)			
		AND RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Bib loose: Author, Title, Record Type",
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Bib loose: Author, Title"		
	);
	
	$queries{'matchQueries'} = \@matchQueries;
	my $success = addBibMatch(\%queries);
	return $success;
}

sub moveCopiesOntoHighestScoringBibCandidate
{
	my $oldbib = @_[0];	
	my $matchReason = @_[1];
	my @copies;
	my $moveOnlyCopies=0;
	if(@_[2])
	{
		$moveOnlyCopies=1;
		@copies = @{$mobUtil->makeArrayFromComma(@_[2])};		
	}
	my $query = "select sbm.bib2,sbs.score from SEEKDESTROY.BIB_MATCH sbm,seekdestroy.bib_score sbs where 
	sbm.bib1=$oldbib and
	sbm.match_reason=\$\$$matchReason\$\$ and
	sbs.record=sbm.bib2
	order by sbs.score";
	$log->addLine("Looking through matches");
	updateJob("Processing","moveCopiesOntoHighestScoringBibCandidate  $query");
	my @results = @{$dbHandler->query($query)};	
	$log->addLine(($#results+1)." potential bibs for destination");
	my $hscore=0;
	my $winner=0;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $score = @row[1];
		$log->addLine("Adding Score Possible: $score - $bibid");
		if($score>$hscore)
		{
			$winner=$bibid;
			$hscore=$score;
		}
	}
	$log->addLine("Winning Score: $hscore - $winner");
	if($winner!=0)
	{
		undeleteBIB($winner);
		#print "moveCopiesOntoHighestScoringBibCandidate from: $oldbib\n";
		if(!$moveOnlyCopies)
		{
			moveAllCallNumbers($oldbib,$winner,$matchReason);
			moveHolds($oldbib,$winner);
		}
		else
		{
			moveCopies(\@copies,$winner,$matchReason);			
		}
		return $winner;
	}
	else
	{
		$query="INSERT INTO SEEKDESTROY.CALL_NUMBER_MOVE(FROMBIB,EXTRA,SUCCESS,JOB)
		VALUES(\$1,\$2,\$3,\$4,\$5)";	
		my @values = ($oldbib,"FAILED - $matchReason",'false',$jobid);
		$log->addLine($query);				
		$log->addLine("$oldbib,\"FAILED - $matchReason\",'false',$jobid");
		updateJob("Processing","moveCopiesOntoHighestScoringBibCandidate  $query");
		$dbHandler->updateWithParameters($query,\@values);		
	}
	return 0;
}

sub moveCopies
{
	my @copies = @{@_[0]};
	my $destBib = @_[1];
	my $reason = @_[2];
	foreach(@copies)
	{		
		my $copyBarcode = $_;
		print "Working on copy $copyBarcode\n";
		my $query = "SELECT OWNING_LIB,EDITOR,CREATOR,LABEL,ID,RECORD FROM ASSET.CALL_NUMBER WHERE ID = 
		(SELECT CALL_NUMBER FROM ASSET.COPY WHERE BARCODE=\$\$$copyBarcode\$\$)";
		my @results = @{$dbHandler->query($query)};					
		foreach(@results)
		{
			my $row = $_;
			my @row = @{$row};
			my $owning_lib = @row[0];
			my $editor = @row[1];
			my $creator = @row[2];
			my $label = @row[3];
			my $oldcall = @row[4];
			my $oldbib = @row[5];
			my $destCallNumber = createCallNumberOnBib($destBib,$label,$owning_lib,$creator,$editor);
			if($destCallNumber!=-1)
			{
				print "received $destCallNumber and moving into recordCopyMove($oldcall,$destCallNumber,$reason)\n";
				recordCopyMove($oldcall,$destCallNumber,$reason);
				$query = "UPDATE ASSET.COPY SET CALL_NUMBER=$destCallNumber WHERE BARCODE=\$\$$copyBarcode\$\$";
				updateJob("Processing","moveCopies  $query");
				$log->addLine($query);
				$log->addLine("Moving $copyBarcode from $oldcall $oldbib to $destCallNumber $destBib" );
				if(!$dryrun)
				{
					$dbHandler->update($query);
				}
			}
			else
			{
				$log->addLine("ERROR! DID NOT GET A CALL NUMBER FROM createCallNumberOnBib($destBib,$label,$owning_lib,$creator,$editor)");
			}
		}
	}
}

sub findPhysicalItemsOnElectronicBooks
{
	my $success = 0;
	# Find Electronic bibs with physical items
	my $subq = $queries{"electronic_book_with_physical_items_attached"};
	my $query = "select id,marc from biblio.record_entry where id in($subq)"; 
	updateJob("Processing","findPhysicalItemsOnElectronic  $query");
	my @results = @{$dbHandler->query($query)};	
	$log->addLine(($#results+1)." Bibs with physical Items attached");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		$success = attemptMovePhysicalItemsOnAnElectronicBook($bibid);		
	}
	
	return $success;
	
}

sub findPhysicalItemsOnElectronicAudioBooksUnDedupe
{
	# Find Electronic bibs with physical items but and in the dedupe project
	my $query = "
	select id,marc from biblio.record_entry where not deleted and lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\">\$\$
	and id in
	(
	select record from asset.call_number where not deleted and id in(select call_number from asset.copy where not deleted)
	)
	and id in
	(select lead_bibid from m_dedupe.merge_map)
	and 
	(
		marc ~ \$\$tag=\"008\">.......................[oqs]\$\$
		or
		marc ~ \$\$tag=\"006\">......[oqs]\$\$
	)
	and
	(
		marc ~ \$\$<leader>......i\$\$
	)	
	";
	updateJob("Processing","findPhysicalItemsOnElectronicAudioBooksUnDedupe  $query");
	my @results = @{$dbHandler->query($query)};
	$log->addLine(($#results+1)." Bibs with physical Items attached from the dedupe");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $marc = @row[1];
		my @scorethis = ($bibid,$marc);
		my @st = ([@scorethis]);		
		updateScoreCache(\@st);
		recordAssetCopyMove($bibid);
	}

}

sub findPhysicalItemsOnElectronicAudioBooks
{
	my $success = 0;
	# Find Electronic Audio bibs with physical items
	my $subq = $queries{"electronic_audiobook_with_physical_items_attached"};
	my $query = "select id,marc from biblio.record_entry where id in($subq)"; 	
	updateJob("Processing","findPhysicalItemsOnElectronicAudioBooks  $query");
	my @results = @{$dbHandler->query($query)};	
	$log->addLine(($#results+1)." Audio Bibs with physical Items attached");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		$success = attemptMovePhysicalItemsOnAnElectronicAudioBook($bibid);		
	}
	
	return $success;
	
}


sub attemptMovePhysicalItemsOnAnElectronicAudioBook
{
	my $oldbib = @_[0];
	my $query;
	my %queries=();
	$queries{'action'} = 'moveallcopies';
	$queries{'problem'} = "Physical items attched to Electronic Audio Bibs";
	my @okmatchingreasons=("Physical Items to Electronic Audio Bib exact","Physical Items to Electronic Audio Bib exact minus date1");
	$queries{'takeActionWithTheseMatchingMethods'}=\@okmatchingreasons;
	$queries{'searchQuery'} = "
	select id,marc from biblio.record_entry where not deleted and lower(marc) ~ \$\$<datafield tag=\"856\" ind1=\"4\" ind2=\"0\">\$\$
	and id in
	(
	select record from asset.call_number where not deleted and id in(select call_number from asset.copy where not deleted)
	)	
	and 
	(
		marc ~ \$\$tag=\"008\">.......................[oqs]\$\$
		or
		marc ~ \$\$tag=\"006\">......[oqs]\$\$
	)
	and
	(
		marc ~ \$\$<leader>......i\$\$
	)
	";
	my @results;
	if($oldbib)
	{
		$queries{'searchQuery'} = "select id,marc from biblio.record_entry where id=$oldbib";
	}
	my @matchQueries = 
	(
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 
		DATE1 = (SELECT DATE1 FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Audio Bib exact",		
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 			
		RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Audio Bib exact minus date1",
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)			
		AND RECORD_TYPE = (SELECT RECORD_TYPE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Audio Bib loose: Author, Title, Record Type",
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND (ELECTRONIC < (SELECT ELECTRONIC FROM seekdestroy.bib_score WHERE RECORD = \$bibid) OR ELECTRONIC < 1)
		AND ITEM_FORM !~ \$\$[oqs]\$\$
		AND RECORD != \$bibid","Physical Items to Electronic Audio Bib loose: Author, Title"		
	);
	
	$queries{'matchQueries'} = \@matchQueries;
	my $success = addBibMatch(\%queries);
	return $success;
}

sub findItemsCircedAsAudioBooksButAttachedNonAudioBib
{
	my $oldbib = @_[0];
	my $query;
	my %sendqueries=();
	$sendqueries{'action'} = 'movesomecopies';
	$sendqueries{'ifaudioscorebelow'} = $audio_book_score_when_audiobooks_dont_belong;
	$sendqueries{'problem'} = "Non-audiobook Bib with items that circulate as 'AudioBooks'";
	my @okmatchingreasons=("AudioBooks attached to non AudioBook Bib exact","AudioBooks attached to non AudioBook Bib exact minus date1");
	$sendqueries{'takeActionWithTheseMatchingMethods'}=\@okmatchingreasons;
	# Find Bibs that are not Audiobooks and have physical items that are circed as audiobooks
	$sendqueries{'searchQuery'} = $queries{"findItemsCircedAsAudioBooksButAttachedNonAudioBib"};
	if($oldbib)
	{
		$sendqueries{'searchQuery'} = "select id,marc from biblio.record_entry where id=$oldbib";
	}
	my @matchQueries = 
	(
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 
		DATE1 = (SELECT DATE1 FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND RECORD_TYPE = \$\$i\$\$
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)		
		AND RECORD != \$bibid","AudioBooks attached to non AudioBook Bib exact",		
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 		
		RECORD_TYPE = \$\$i\$\$
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)		
		AND RECORD != \$bibid","AudioBooks attached to non AudioBook Bib exact minus date1",		
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)			
		AND RECORD_TYPE = \$\$i\$\$
		AND RECORD != \$bibid","AudioBooks attached to non AudioBook Bib loose"
				
	);
	
	$sendqueries{'matchQueries'} = \@matchQueries;
	my $success = addBibMatch(\%sendqueries);
	return $success;
}


sub findItemsNotCircedAsAudioBooksButAttachedAudioBib
{
	my $oldbib = @_[0];
	my $query;
	my %queries=();
	$queries{'action'} = 'movesomecopies';
	$queries{'ifaudioscoreabove'} = $audio_book_score_when_audiobooks_dont_belong;
	$queries{'problem'} = "Audiobook Bib with items that do not circulate as 'AudioBooks'";
	my @okmatchingreasons=("Non-AudioBooks attached to AudioBook Bib exact","Non-AudioBooks attached to AudioBook Bib exact minus date1");
	$queries{'takeActionWithTheseMatchingMethods'}=(); #\@okmatchingreasons;
	# Find Bibs that are Audiobooks and have physical items that are not circed as audiobooks
	$queries{'searchQuery'} = "
	select bre.id,bre.marc,string_agg(ac.barcode,\$\$,\$\$) from biblio.record_entry bre, asset.copy ac, asset.call_number acn where 
bre.marc ~ \$\$<leader>......i\$\$
and
bre.id=acn.record and
acn.id=ac.call_number and
not acn.deleted and
not ac.deleted and
ac.circ_modifier not in ( \$\$AudioBooks\$\$,\$\$CD\$\$ )
group by bre.id,bre.marc
limit 1000
	";
	if($oldbib)
	{
		$queries{'searchQuery'} = "select id,marc from biblio.record_entry where id=$oldbib";
	}
	my @matchQueries = 
	(
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 
		DATE1 = (SELECT DATE1 FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND RECORD_TYPE != \$\$i\$\$
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)		
		AND RECORD != \$bibid","Non-AudioBooks attached to AudioBook Bib exact",		
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE 		
		RECORD_TYPE != \$\$i\$\$
		AND BIB_LVL = (SELECT BIB_LVL FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid) 
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)		
		AND RECORD != \$bibid","Non-AudioBooks attached to AudioBook Bib exact minus date1",		
		
		"SELECT RECORD FROM  seekdestroy.bib_score
		WHERE TITLE = (SELECT TITLE FROM seekdestroy.bib_score WHERE RECORD = \$bibid)
		AND AUTHOR = (SELECT AUTHOR FROM seekdestroy.bib_score WHERE RECORD = \$bibid)			
		AND RECORD_TYPE = \$\$i\$\$
		AND RECORD != \$bibid","Non-AudioBooks attached to AudioBook Bib Bib loose"
				
	);
	
	$queries{'matchQueries'} = \@matchQueries;
	my $success = addBibMatch(\%queries);
	return $success;
}

sub updateScoreWithQuery
{
	my $query = @_[0];
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $bibid = @row[0];
		my $marc = @row[1];
		my @scorethis = ($bibid,$marc);
		#$log->addLine("Scoring: $bibid");
		my @st = ([@scorethis]);
		updateScoreCache(\@st);
	}
}

sub findPossibleDups
{

#
# Gather up some potential candidates based on EG Fingerprints
#
	my $query="
		select string_agg(to_char(id,\$\$9999999999\$\$),\$\$,\$\$),fingerprint from biblio.record_entry where fingerprint in
		(
		select fingerprint from(
		select fingerprint,count(*) \"count\" from biblio.record_entry where not deleted 
		and id not in(select record from seekdestroy.bib_score)
		group by fingerprint
		) as a
		where count>1
		)
		and not deleted
		and fingerprint != \$\$\$\$
		group by fingerprint
		limit 10;
		";
updateJob("Processing","findPossibleDups  $query");
	my @results = @{$dbHandler->query($query)};
	my @st=();
	my %alreadycached;
	my $deleteoldscorecache="";
updateJob("Processing","findPossibleDups  looping results");
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my @ids=split(',',@row[0]);
		my $fingerprint = @row[1];
		for my $i(0..$#ids)
		{
			@ids[$i]=$mobUtil->trim(@ids[$i]);
			my $id = @ids[$i];
			if(!$alreadycached{$id})
			{
				$alreadycached{$id}=1;
				my $q = "select marc from biblio.record_entry where id=$id";
				my @result = @{$dbHandler->query($q)};			
				my @r = @{@result[0]};
				my $marc = @r[0];
				my @scorethis = ($id,$marc);
				push(@st,[@scorethis]);
				$deleteoldscorecache.="$id,";
			}
		}
	}

	$deleteoldscorecache=substr($deleteoldscorecache,0,-1);		
	my $q = "delete from SEEKDESTROY.BIB_MATCH where (BIB1 IN( $deleteoldscorecache) OR BIB2 IN( $deleteoldscorecache)) and job=$jobid";
	updateJob("Processing","findPossibleDups deleting old cache bib_match   $query");
	print $dbHandler->update($q);	
	updateJob("Processing","findPossibleDups updating scorecache selectivly");
	updateScoreCache(\@st);
	
	
	my $query="
			select record,sd_fingerprint,score from seekdestroy.bib_score sbs2 where sd_fingerprint in(
		select sd_fingerprint from(
		select sd_fingerprint,count(*) from seekdestroy.bib_score sbs where length(btrim(regexp_replace(regexp_replace(sbs.sd_fingerprint,\$\$\t\$\$,\$\$\$\$,\$\$g\$\$),\$\$\s\$\$,\$\$\$\$,\$\$g\$\$)))>5 
		and record not in(select id from biblio.record_entry where deleted)
		group by sd_fingerprint having count(*) > 1) as a 
		)
		--and record not in(select id from biblio.record_entry where deleted)
		order by sd_fingerprint,score desc, record
		";
		$log->addLine($query);
updateJob("Processing","findPossibleDups  $query");
	my @results = @{$dbHandler->query($query)};
	my $current_fp ='';
	my $master_record=-2;
	my %mergeMap;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $record=@row[0];
		my $fingerprint = @row[1];
		my $score= @row[2];
		
		if($current_fp ne $fingerprint)
		{
			$current_fp=$fingerprint;
			$master_record = $record;
			$mergeMap{$master_record}=();
		}
		else
		{
			my $hold = findHoldsOnBib($record, $dbHandler);
			my $q = "INSERT INTO SEEKDESTROY.BIB_MATCH(BIB1,BIB2,MATCH_REASON,HAS_HOLDS,JOB)
			VALUES(\$1,\$2,\$3,\$4,\$5)";
			my @values = ($master_record,$record,"Duplicate SD Fingerprint",$hold,$jobid);
			$dbHandler->updateWithParameters($q,\@values);
			push ($mergeMap{$master_record},$record);
		}
	}
	$log->addLine(Dumper(\%mergeMap));
}

sub findHoldsOnBib
{
	my $bibid=@_[0];	
	my $hold = 0;
	my $query = "select id from action.hold_request ahr where 
	ahr.target=$bibid and
	ahr.hold_type=\$\$T\$\$ and
	ahr.capture_time is null and
	ahr.cancel_time is null";
	updateJob("Processing","findHolds $query");
	my @results = @{$dbHandler->query($query)};
	if($#results != -1)
	{
		$hold=1;
	}
	#print "returning $hold\n";
	return $hold
}

sub recordAssetCopyMove
{
	my $oldbib = @_[0];		
	my $query = "select distinct call_number from asset.copy where call_number in(select id from asset.call_number where record in($oldbib) and label!=\$\$##URI##\$\$)";
	my @cids;
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my @row = @{$_};
		push(@cids,@row[0]);
	}
	
	if($#cids>-1)
	{		
		#attempt to put those asset.copies back onto the previously deleted bib from m_dedupe
		moveAssetCopyToPreviouslyDedupedBib($oldbib);		
	}
	
	#Check again after the attempt to undedupe
	@cids = ();
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my @row = @{$_};
		push(@cids,@row[0]);
	}
	if($#cids>-1)
	{
		attemptMovePhysicalItemsOnAnElectronicBook($oldbib);
	}
	@cids = ();
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my @row = @{$_};
		my $callnum= @row[0];
		print "There were asset.copies on $oldbib even after attempting to put them on a deduped bib\n";
		$log->addLine("\t$oldbib\tContained physical Items");
		$query="INSERT INTO SEEKDESTROY.CALL_NUMBER_MOVE(CALL_NUMBER,FROMBIB,EXTRA,SUCCESS,JOB)
		VALUES(\$1,\$2,\$3,\$4,\$5)";
		my @values = ($callnum,$oldbib,"FAILED",'false',$jobid);
		$log->addLine($query);
		updateJob("Processing","recordAssetCopyMove  $query");
		$dbHandler->updateWithParameters($query,\@values);
	}
}

sub moveAssetCopyToPreviouslyDedupedBib
{
	my $currentBibID = @_[0];
	my %possibles;	
	my $query = "select mmm.sub_bibid,bre.marc from m_dedupe.merge_map mmm, biblio.record_entry bre 
	where lead_bibid=$currentBibID and bre.id=mmm.sub_bibid
	and
	bre.marc !~ \$\$tag=\"008\">.......................[oqs]\$\$
	and
	bre.marc !~ \$\$tag=\"006\">......[oqs]\$\$
	";
updateJob("Processing","moveAssetCopyToPreviouslyDedupedBib  $query");
	#print $query."\n";
	my @results = @{$dbHandler->query($query)};
	my $winner=0;
	my $currentWinnerElectricScore=10000;
	my $currentWinnerMARCScore=0;
	foreach(@results)
	{
		my @row = @{$_};
		my $prevmarc = @row[1];
		$prevmarc =~ s/(<leader>.........)./${1}a/;
		$prevmarc = MARC::Record->new_from_xml($prevmarc);
		my @temp=($prevmarc,determineElectricScore($prevmarc),scoreMARC($prevmarc));
		#need to initialize the winner values
		$winner=@row[0];
		$currentWinnerElectricScore = @temp[1];
		$currentWinnerMARCScore = @temp[2];
		$possibles{@row[0]}=\@temp;
	}
	
	#choose the best deleted bib - we want the lowest electronic bib score in this case because we want to attach the 
	#items to the *most physical bib
	while ((my $bib, my $attr) = each(%possibles))
	{
		my @atts = @{$attr};
		if(@atts[1]<$currentWinnerElectricScore)
		{
			$winner=$bib;
			$currentWinnerElectricScore=@atts[1];
			$currentWinnerMARCScore=@atts[2];
		}
		elsif(@atts[1]==$currentWinnerElectricScore && @atts[2]>$currentWinnerMARCScore)
		{
			$winner=$bib;
			$currentWinnerElectricScore=@atts[1];
			$currentWinnerMARCScore=@atts[2];
		}
	}
	if($winner!=0)
	{
		undeleteBIB($winner);
		#find all of the eligible call_numbers
		$query = "SELECT ID FROM ASSET.CALL_NUMBER WHERE RECORD=$currentBibID AND LABEL!= \$\$##URI##\$\$";
updateJob("Processing","moveAssetCopyToPreviouslyDedupedBib  $query");
		my @results = @{$dbHandler->query($query)};
		foreach(@results)
		{	
			my @row = @{$_};
			my $acnid = @row[0];			
			my $callNID = moveCallNumber($acnid,$currentBibID,$winner,"Dedupe pool");
			$query = 
			"INSERT INTO seekdestroy.undedupe(oldleadbib,undeletedbib,undeletedbib_electronic_score,undeletedbib_marc_score,moved_call_number,job)
			VALUES($currentBibID,$winner,$currentWinnerElectricScore,$currentWinnerMARCScore,$callNID,$jobid)";
updateJob("Processing","moveAssetCopyToPreviouslyDedupedBib  $query");							
			$log->addLine($query);
			$dbHandler->update($query);
		}
		moveHolds($currentBibID,$winner);
	}
}

sub undeleteBIB
{
	my $bib = @_[0];	
	my $query = "select deleted from biblio.record_entry where id=$bib";
	my @results = @{$dbHandler->query($query)};
	foreach(@results)
	{	
		my $row = $_;
		my @row = @{$row};			
		#make sure that it is in fact deleted
		if(@row[0] eq 't' || @row[0] == 1)
		{
			my $tcn_value = $bib;
			my $count=1;			
			#make sure that when we undelete it, it will not collide its tcn_value 
			while($count>0)
			{
				$query = "select count(*) from biblio.record_entry where tcn_value = \$\$$tcn_value\$\$ and id != $bib";
				$log->addLine($query);
updateJob("Processing","undeleteBIB  $query");
				my @results = @{$dbHandler->query($query)};
				foreach(@results)
				{	
					my $row = $_;
					my @row = @{$row};
					$count=@row[0];
				}
				$tcn_value.="_";
			}
			#take the last tail off
			$tcn_value=substr($tcn_value,0,-1);
			#finally, undelete the bib making it available for the asset.call_number
			$query = "update biblio.record_entry set deleted='f',tcn_source='un-deduped',tcn_value = \$\$$tcn_value\$\$  where id=$bib";
			$dbHandler->update($query);
		}
	}
}

sub moveAllCallNumbers
{
	my $oldbib = @_[0];
	my $destbib = @_[1];
	my $matchReason = @_[2];
	
	my $query = "select id from asset.call_number where record=$oldbib and label!=\$\$##URI##\$\$";
	$log->addLine($query);
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my @row = @{$_};
		my $calln = @row[0];
		#print "moveAllCallNumbers from: $oldbib\n";
		moveCallNumber($calln,$oldbib,$destbib,$matchReason);
	}
	
}

sub recordCopyMove
{
	my $callnumberid = @_[0];
	my $destcall = @_[1];
	my $matchReason = @_[2];
	my $query = "SELECT ID FROM ASSET.COPY WHERE CALL_NUMBER=$callnumberid";
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my @row = @{$_};
		my $copy = @row[0];
		$query="INSERT INTO SEEKDESTROY.COPY_MOVE(COPY,FROMCALL,TOCALL,EXTRA,JOB) VALUES(\$1,\$2,\$3,\$4,\$5)";
		my @values = ($copy,$callnumberid,$destcall,$matchReason,$jobid);
		#$log->addLine($query);
		$dbHandler->updateWithParameters($query,\@values);
	}
}

sub recordCallNumberMove
{
	my $callnumber = @_[0];
	my $record = @_[1];
	my $destrecord = @_[2];
	my $matchReason = @_[3];	
	
	#print "recordCallNumberMove from: $record\n";
	if($mobUtil->trim(length($destrecord))<1)
	{
		$log->addLine("tobib is null - \$callnumber=$callnumber, FROMBIB=$record, \$matchReason=$matchReason");
	}
	my $query="INSERT INTO SEEKDESTROY.CALL_NUMBER_MOVE(CALL_NUMBER,FROMBIB,TOBIB,EXTRA,JOB) VALUES(\$1,\$2,\$3,\$4,\$5)";	
	my @values = ($callnumber,$record,$destrecord,$matchReason,$jobid);
	$log->addLine($query);
	$dbHandler->updateWithParameters($query,\@values);
}
	
sub moveCallNumber
{
	my $callnumberid = @_[0];
	my $frombib = @_[1];
	#print "moveCallNumber from: $frombib\n";
	my $destbib = @_[2];
	my $matchReason = @_[3];

	my $finalCallNumber = $callnumberid;
	my $query = "SELECT ID,LABEL,RECORD FROM ASSET.CALL_NUMBER WHERE RECORD = $destbib
	AND LABEL=(SELECT LABEL FROM ASSET.CALL_NUMBER WHERE ID = $callnumberid ) 
	AND OWNING_LIB=(SELECT OWNING_LIB FROM ASSET.CALL_NUMBER WHERE ID = $callnumberid ) AND NOT DELETED";
	
	my $moveCopies=0;
	my @results = @{$dbHandler->query($query)};
	#print "about to loop the callnumber results\n";
	foreach(@results)
	{
		#print "it had a duplciate call number\n";
		## Call number already exists on that record for that 
		## owning library and label. So let's just move the 
		## copies to it instead of moving the call number			
		$moveCopies=1;		
		my @row = @{$_};
		my $destcall = @row[0];
		$log->addLine("Call number $callnumberid had a match on the destination bib $destbib and we will be moving the copies to the call number instead of moving the call number");
		recordCopyMove($callnumberid,$destcall,$matchReason);	
		$query = "UPDATE ASSET.COPY SET CALL_NUMBER=$destcall WHERE CALL_NUMBER=$callnumberid";
		updateJob("Processing","moveCallNumber  $query");
		$log->addLine("Moving copies from $callnumberid call number to $destcall");
		if(!$dryrun)
		{
			$dbHandler->update($query);
		}
		$finalCallNumber=$destcall;
	}
	
	if(!$moveCopies)
	{	
	#print "it didnt have a duplciate call number... going into recordCallNumberMove\n";
		recordCallNumberMove($callnumberid,$frombib,$destbib,$matchReason);		
		#print "done with recordCallNumberMove\n";
		$query="UPDATE ASSET.CALL_NUMBER SET RECORD=$destbib WHERE ID=$callnumberid";
		$log->addLine($query);
		updateJob("Processing","moveCallNumber  $query");
		$log->addLine("Moving call number $callnumberid from record $frombib to $destbib");
		if(!$dryrun)
		{
			$dbHandler->update($query);
		}
	}
	return $finalCallNumber;

}

sub createCallNumberOnBib
{
	my $bibid = @_[0];
	my $call_label = @_[1];
	my $owning_lib = @_[2];
	my $creator = @_[3];
	my $editor = @_[4];
	my $query = "SELECT ID FROM ASSET.CALL_NUMBER WHERE LABEL=\$\$$call_label\$\$ AND RECORD=$bibid AND OWNING_LIB=$owning_lib";
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};	
		print "got a call number that was on the record already\n";
		return @row[0];
	}
	$query = "INSERT INTO ASSET.CALL_NUMBER (CREATOR,EDITOR,OWNING_LIB,LABEL,LABEL_CLASS,RECORD) 
	VALUES (\$1,\$2,\$3,\$4,\$5,\$6)";
	$log->addLine($query);
	$log->addLine("$creator,$editor,$owning_lib,$call_label,1,$bibid");
	my @values = ($creator,$editor,$owning_lib,$call_label,1,$bibid);
	if(!$dryrun)
	{	
		$dbHandler->updateWithParameters($query,\@values);
	}
	print "Creating new call number: $creator,$editor,$owning_lib,$call_label,1,$bibid \n";
	$query = "SELECT ID FROM ASSET.CALL_NUMBER WHERE LABEL=\$\$$call_label\$\$ AND RECORD=$bibid AND OWNING_LIB=$owning_lib";
	my @results = @{$dbHandler->query($query)};	
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		if($mobUtil->trim(length($bibid))<1)
		{
			$log->addLine("bibid is null - \$callnumber=".@row[0]." createCallNumberOnBib OWNING_LIB=$owning_lib LABEL=$call_label");
		}
		$query="INSERT INTO SEEKDESTROY.CALL_NUMBER_MOVE(CALL_NUMBER,TOBIB,JOB) VALUES(\$1,\$2,\$3)";
		@values = (@row[0],$bibid,$jobid);
		$log->addLine($query);
		$dbHandler->updateWithParameters($query,\@values);
		return @row[0];
	}
	return -1;	
}

sub moveHolds
{
	my $oldBib = @_[0];
	my $newBib = @_[1];
	my $query = "UPDATE ACTION.HOLD_REQUEST SET TARGET=$newBib WHERE TARGET=$oldBib AND HOLD_TYPE=\$\$T\$\$ AND fulfillment_time IS NULL AND capture_time IS NULL AND cancel_time IS NULL"; 
	$log->addLine($query);
	updateJob("Processing","moveHolds  $query");
	#print $query."\n";
	if(!$dryrun)
	{
		$dbHandler->update($query);
	}
}

sub getAllScores
{
	my $marc = @_[0];
	my %allscores = ();
	$allscores{'electricScore'}=determineElectricScore($marc);
	$allscores{'audioBookScore'}=determineAudioBookScore($marc);
	$allscores{'largeprint_score'}=determineLargePrintScore($marc);
	$allscores{'video_score'}=determineScoreWithPhrases($marc,\@videoSearchPhrases);
	$allscores{'microfilm_score'}=determineScoreWithPhrases($marc,\@microfilmSearchPhrases);
	$allscores{'microfiche_score'}=determineScoreWithPhrases($marc,\@microficheSearchPhrases);
	$allscores{'music_score'}=determineMusicScore($marc);
	$allscores{'playaway_score'}=determineScoreWithPhrases($marc,\@playawaySearchPhrases);
	my $highname='';
	my $highscore=0;
	my $highscoredistance=0;
	my $secondplacename='';
	while ((my $scorename, my $score ) = each(%allscores))
	{
		my $tempdistance=$highscore-$score;
		if($score>$highscore)
		{
			$secondplacename=$highname;
			$highname=$scorename;
			$highscoredistance=($score-$highscore);
			$highscore=$score;
		}
		elsif($score==$highscore)
		{
			$highname.=' tied '.$scorename;
			$highscoredistance=0;
			$secondplacename='';
		}
		elsif($tempdistance<$highscoredistance)
		{
			$highscoredistance=$tempdistance;
			$secondplacename=$scorename;
		}
	}
	# There is no second place when the high score is the same as the distance
	# Meaning it's next contender scored a fat 0
	if($highscoredistance==$highscore)
	{
		$secondplacename='';
	}
	$allscores{'winning_score'}=$highname;
	$allscores{'winning_score_score'}=$highscore;
	$allscores{'winning_score_distance'}=$highscoredistance;
	$allscores{'second_place_score'}=$secondplacename;
	
	return \%allscores;
}

sub determineElectricScore
{
	my $marc = @_[0];
	my @e56s = $marc->field('856');
	my @two45 = $marc->field('245');
	if(!@e56s)
	{
		return 0;
	}
	$marc->delete_fields(@two45);
	my $textmarc = $marc->as_formatted();
	$marc->insert_fields_ordered(@two45);
	my $score=0;
	my $found=0;	
	foreach(@e56s)
	{
		my $field = $_;
		my $ind2 = $field->indicator(2);		
		if($ind2 eq '0') #only counts if the second indicator is 0 ("Resource") documented here: http://www.loc.gov/marc/bibliographic/bd856.html
		{	
			my @subs = $field->subfield('u');
			foreach(@subs)
			{
				#print "checking $_ for http\n";
				if(m/http/g)
				{
					$found=1;
				}
			}
		}
	}
	foreach(@two45)
	{
		my $field = $_;		
		my @subs = $field->subfield('h');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@electronicSearchPhrases)
			{
				#if the phrases are found in the 245h, they are worth 5 each
				my $phrase=lc($_);
				if($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245h");
				}
			}
		}
	}
	if($found)
	{
		$score++;
	}
	foreach(@electronicSearchPhrases)
	{
		my $phrase = lc$_;
		my @c = split(lc$phrase,lc$textmarc);
		if($#c>1) # Found at least 2 matches on that phrase
		{
			$score++;
		}
	}
	#print "Electric score: $score\n";
	return $score;
}


sub determineMusicScore
{
	my $marc = @_[0];	
	my @two45 = $marc->field('245');
	#$log->addLine(getsubfield($marc,'245','a'));
	$marc->delete_fields(@two45);
	my $textmarc = lc($marc->as_formatted());
	$marc->insert_fields_ordered(@two45);
	my $score=0;
	
	foreach(@two45)
	{
		my $field = $_;		
		my @subs = $field->subfield('h');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@musicSearchPhrases)
			{
				#if the phrases are found in the 245h, they are worth 5 each
				my $phrase=lc($_);
				if($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245h");
				}
			}
		}
	}
	foreach(@musicSearchPhrases)
	{
		my $phrase = lc$_;
		
		if($textmarc =~ m/$phrase/g) # Found at least 1 match on that phrase
		{
			$score++;
			#$log->addLine("$phrase + 1 points elsewhere");
		}
	}
	
	# if the 505 contains a bunch of $t's then it's defiantly a music bib
	my @five05 = $marc->field('505');
	my $tcount;
	foreach(@five05)
	{
		my $field = $_;
		my @subfieldts = $field->subfield('t');
		foreach(@subfieldts)
		{
			$tcount++;
		}
		
	}
	#tip the score to music if those subfield t's are found (these are track listings)
	$score=100 unless $tcount<4;
	
	my @nonmusicphrases = ('non music', 'non-music', 'abridge');
	# Make the score 0 if non musical shows up
	my @tags = $marc->fields();
	my $found=0;
	foreach(@tags)
	{
		my $field = $_;
		my @subfields = $field->subfields();
		foreach(@subfields)
		{
			my @subfield=@{$_};
			my $test = lc(@subfield[1]);
			#$log->addLine("0 = ".@subfield[0]."  1 = ".@subfield[1]);
			foreach(@nonmusicphrases)
			{
				my $phrase = lc$_;
				#$log->addLine("$test\nfor\n$phrase");				
				if($test =~ m/$phrase/g) # Found at least 1 match on that phrase
				{
					$score=0;
					$found=1;
					#$log->addLine("$phrase 0 points!");
				}
				last if $found;
			}
			last if $found;
		}
		last if $found;
	}
	
	
	return $score;
}


sub determineAudioBookScore
{
	my $marc = @_[0];
	my @two45 = $marc->field('245');
	my @isbn = $marc->field('020');
	$marc->delete_fields(@isbn);
	$marc->delete_fields(@two45);	
	my $textmarc = lc($marc->as_formatted());
	$marc->insert_fields_ordered(@two45);
	$marc->insert_fields_ordered(@isbn);
	my $score=0;
	
	foreach(@two45)
	{
		my $field = $_;		
		my @subs = $field->subfield('h');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@audioBookSearchPhrases)
			{
				#if the phrases are found in the 245h, they are worth 5 each
				my $phrase=lc($_);
				if($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245h");
				}
			}
		}
	}
	foreach(@audioBookSearchPhrases)
	{
		my $phrase = lc$_;		
		if($textmarc =~ m/$phrase/g) # Found at least 1 match on that phrase
		{
			$score++;
			#$log->addLine("$phrase + 1 points elsewhere");
		}
	}
	
	return $score;
}

# Dead function - decided to score the same as the rest
sub determinePlayawayScore
{
	my $marc = @_[0];		
	my $score=0;
	my @isbn = $marc->field('020');
	$marc->delete_fields(@isbn);
	my $textmarc = lc($marc->as_formatted());
	$marc->insert_fields_ordered(@isbn);
	my @zero07 = $marc->field('007');
	my %zero07looking = ('cz'=>0,'sz'=>0);
	
	foreach(@playawaySearchPhrases)
	{
		my $phrase = lc$_;		
		if($textmarc =~ m/$phrase/g) # Found at least 1 match on that phrase
		{
			$score++;
			#$log->addLine("$phrase + 1 points elsewhere");
		}
	}
	
	if($#zero07>0)
	{
		foreach(@zero07)
		{
			my $field=$_;
			while ((my $looking, my $val ) = each(%zero07looking))
			{		
				if($field->data() =~ m/^$looking/)
				{
					$zero07looking{$looking}=1;
				}
			}
		}
		if($zero07looking{'cz'} && $zero07looking{'sz'})
		{
			my $my_008 = $marc->field('008')->data();
			my $my_006 = $marc->field('006')->data() unless not defined $marc->field('006');
			my $type = substr($marc->leader, 6, 1);				
			my $form=0;
			if($my_008)
			{
				$form = substr($my_008,23,1) if ($my_008 && (length $my_008 > 23 ));			
			}
			if (!$form)
			{
				$form = substr($my_006,6,1) if ($my_006 && (length $my_006 > 6 ));
			}			
			if($type eq 'i' && $form eq 'q')
			{
				$score=100;
			}
		}
	}
	
	return $score;
}

sub determineLargePrintScore
{
	my $marc = @_[0];
	my @searchPhrases = @largePrintBookSearchPhrases;
	my @two45 = $marc->field('245');
	#$log->addLine(getsubfield($marc,'245','a'));
	$marc->delete_fields(@two45);
	my $textmarc = lc($marc->as_formatted());
	$marc->insert_fields_ordered(@two45);
	my $score=0;
	#$log->addLine(lc$textmarc);
	foreach(@two45)
	{
		my $field = $_;		
		my @subs = $field->subfield('h');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@searchPhrases)
			{
				#if the phrases are found in the 245h, they are worth 5 each
				my $phrase=lc($_);
				#ignore the centerpoint/center point search phrase, those need to only match in the 260,262
				if($phrase =~ m/center/g)
				{}
				elsif($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245h");
				}
			}
		}
		my @subs = $field->subfield('a');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@searchPhrases)
			{
				#if the phrases are found in the 245a, they are worth 5 each
				my $phrase=lc($_);
				#ignore the centerpoint/center point search phrase, those need to only match in the 260,264
				if($phrase =~ m/center/g)
				{}
				elsif($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245a");
				}
			}
		}
	}
	foreach(@searchPhrases)
	{
		my $phrase = lc$_;
		#ignore the centerpoint/center point search phrase, those need to only match in the 260,264
		if($phrase =~ m/center/g)
		{}
		elsif($textmarc =~ m/$phrase/g) # Found at least 1 match on that phrase
		{
			$score++;
			#$log->addLine("$phrase + 1 points elsewhere");
		}
	}
	my @two60 = $marc->field('260');
	my @two64 = $marc->field('264');
	my @both = (@two60,@two64);
	foreach(@two60)
	{
		my $field = $_;		
		my @subs = $field->subfields();
		my @matches=(0,0);
		foreach(@subs)
		{
			my @s = @{$_};
			foreach(@s)
			{				
				my $subf = lc($_);
				#$log->addLine("Checking $subf");
				if($subf =~ m/centerpoint/g)
				{
					if(@matches[0]==0)
					{
						$score++;
						@matches[0]=1;
						#$log->addLine("centerpoint + 1 points");
					}
				}
				if($subf =~ m/center point/g)
				{
					if(@matches[1]==0)
					{
						$score++;
						@matches[1]=1;
						#$log->addLine("center point + 1 points");
					}
				}
			}
		}
	}
	return $score;
}

sub determineScoreWithPhrases
{
	my $marc = @_[0];
	my @searchPhrases = @{@_[1]};
	my @two45 = $marc->field('245');
	#$log->addLine(getsubfield($marc,'245','a'));
	$marc->delete_fields(@two45);
	my $textmarc = lc($marc->as_formatted());
	$marc->insert_fields_ordered(@two45);
	my $score=0;
	#$log->addLine(lc$textmarc);
	foreach(@two45)
	{
		my $field = $_;		
		my @subs = $field->subfield('h');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@searchPhrases)
			{
				#if the phrases are found in the 245h, they are worth 5 each
				my $phrase=lc($_);
				if($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245h");
				}
			}
		}
		my @subs = $field->subfield('a');
		foreach(@subs)
		{
			my $subf = lc($_);
			foreach(@searchPhrases)
			{
				#if the phrases are found in the 245a, they are worth 5 each
				my $phrase=lc($_);
				if($subf =~ m/$phrase/g)
				{
					$score+=5;
					#$log->addLine("$phrase + 5 points 245a");
				}
			}
		}
	}
	foreach(@searchPhrases)
	{
		my $phrase = lc$_;
		#$log->addLine("$phrase");		
		if($textmarc =~ m/$phrase/g) # Found at least 1 match on that phrase
		{
			$score++;
			#$log->addLine("$phrase + 1 points elsewhere");
		}
	}
	return $score;
}

sub identifyBibsToScore
{
	my @ret;
#This query finds bibs that have not received a score at all
	my $query = "SELECT ID,MARC FROM BIBLIO.RECORD_ENTRY WHERE ID NOT IN(SELECT RECORD FROM SEEKDESTROY.BIB_SCORE) AND DELETED IS FALSE LIMIT 100";
	my @results = @{$dbHandler->query($query)};
	my @news;
	my @updates;
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $id = @row[0];
		my $marc = @row[1];
		my @temp = ($id,$marc);
		push (@news, [@temp]);
	}
#This query finds bibs that have received but the marc has changed since the last score
	$query = "SELECT SBS.RECORD,BRE.MARC,SBS.ID,SCORE FROM SEEKDESTROY.BIB_SCORE SBS,BIBLIO.RECORD_ENTRY BRE WHERE SBS.score_time < BRE.EDIT_DATE AND SBS.RECORD=BRE.ID";
	@results = @{$dbHandler->query($query)};
	foreach(@results)
	{
		my $row = $_;
		my @row = @{$row};
		my $rec = @row[0];
		my $marc = @row[1];
		my $id = @row[2];
		my $score = @row[3];
		my @temp = ($rec,$marc,$id,$score);
		push (@updates, [@temp]);
	}
	push(@ret,[@news]);
	push(@ret,[@updates]);
	return \@ret;
}

sub scoreMARC
{
	my $marc = shift;	
	
	my $score = 0;
	$score+= score($marc,2,100,400,'245');
	$score+= score($marc,1,1,150,'100');
	$score+= score($marc,1,1.1,150,'110');
	$score+= score($marc,0,50,200,'6..');
	$score+= score($marc,0,50,100,'02.');
	
	$score+= score($marc,0,100,200,'246');
	$score+= score($marc,0,100,100,'130');
	$score+= score($marc,0,100,100,'010');
	$score+= score($marc,0,100,200,'490');
	$score+= score($marc,0,10,50,'830');
	
	$score+= score($marc,1,.5,50,'300');
	$score+= score($marc,0,1,100,'7..');
	$score+= score($marc,2,2,100,'50.');
	$score+= score($marc,2,2,100,'52.');
	
	$score+= score($marc,2,.5,200,'51.', '53.', '54.', '55.', '56.', '57.', '58.');

	return $score;
}

sub score
{
	my ($marc) = shift;
	my ($type) = shift;
	my ($weight) = shift;
	my ($cap) = shift;
	my @tags = @_;
	my $ou = Dumper(@tags);
	#$log->addLine("Tags: $ou\n\nType: $type\nWeight: $weight\nCap: $cap");
	my $score = 0;			
	if($type == 0) #0 is field count
	{
		#$log->addLine("Calling count_field");
		$score = count_field($marc,\@tags);
	}
	elsif($type == 1) #1 is length of field
	{
		#$log->addLine("Calling field_length");
		$score = field_length($marc,\@tags);
	}
	elsif($type == 2) #2 is subfield count
	{
		#$log->addLine("Calling count_subfield");
		$score = count_subfield($marc,\@tags);
	}
	$score = $score * $weight;
	if($score > $cap)
	{
		$score = $cap;
	}
	$score = int($score);
	#$log->addLine("Weight and cap applied\nScore is: $score");
	return $score;
}

sub count_subfield
{
	my ($marc) = $_[0];	
	my @tags = @{$_[1]};
	my $total = 0;
	#$log->addLine("Starting count_subfield");
	foreach my $tag (@tags) 
	{
		my @f = $marc->field($tag);
		foreach my $field (@f)
		{
			my @subs = $field->subfields();
			my $ou = Dumper(@subs);
			#$log->addLine($ou);
			if(@subs)
			{
				$total += scalar(@subs);
			}
		}
	}
	#$log->addLine("Total Subfields: $total");
	return $total;
	
}	

sub count_field 
{
	my ($marc) = $_[0];	
	my @tags = @{$_[1]};
	my $total = 0;
	foreach my $tag (@tags) 
	{
		my @f = $marc->field($tag);
		$total += scalar(@f);
	}
	return $total;
}

sub field_length 
{
	my ($marc) = $_[0];	
	my @tags = @{$_[1]};

	my @f = $marc->field(@tags[0]);
	return 0 unless @f;
	my $len = length($f[0]->as_string);
	my $ou = Dumper(@f);
	#$log->addLine($ou);
	#$log->addLine("Field Length: $len");
	return $len;
}

sub calcSHA1
{
	my $marc = @_[0];
	my $sha1 = Digest::SHA1->new;
	$sha1->add(  length(getsubfield($marc,'007',''))>6 ? substr( getsubfield($marc,'007',''),0,6) : '' );
	$sha1->add(getsubfield($marc,'245','h'));
	$sha1->add(getsubfield($marc,'001',''));
	$sha1->add(getsubfield($marc,'245','a'));
	return $sha1->hexdigest;
}

sub getsubfield
{
	my $marc = @_[0];
	my $tag = @_[1];
	my $subtag = @_[2];
	my $ret;
	#print "Extracting $tag $subtag\n";
	if($marc->field($tag))
	{
		if($tag<10)
		{	
			#print "It was less than 10 so getting data\n";
			$ret = $marc->field($tag)->data();
		}
		elsif($marc->field($tag)->subfield($subtag))
		{
			$ret = $marc->field($tag)->subfield($subtag);
		}
	}
	#print "got $ret\n";
	return $ret;
	
}

sub mergeMARC856
{
	my $marc = @_[0];
	my $marc2 = @_[1];	
	my @eight56s = $marc->field("856");
	my @eight56s_2 = $marc2->field("856");
	my @eights;
	my $original856 = $#eight56s + 1;
	@eight56s = (@eight56s,@eight56s_2);

	my %urls;  
	foreach(@eight56s)
	{
		my $thisField = $_;
		my $ind2 = $thisField->indicator(2);
		# Just read the first $u and $z
		my $u = $thisField->subfield("u");
		my $z = $thisField->subfield("z");
		my $s7 = $thisField->subfield("7");
		
		if($u) #needs to be defined because its the key
		{
			if(!$urls{$u})
			{
				if($ind2 ne '0')
				{
					$thisField->delete_subfields('9');
					$thisField->delete_subfields('z');
				}
				$urls{$u} = $thisField;
			}
			else
			{
				my @nines = $thisField->subfield("9");
				my $otherField = $urls{$u};
				my @otherNines = $otherField->subfield("9");
				my $otherZ = $otherField->subfield("z");		
				my $other7 = $otherField->subfield("7");
				if(!$otherZ)
				{
					if($z)
					{
						$otherField->add_subfields('z'=>$z);
					}
				}
				if(!$other7)
				{
					if($s7)
					{
						$otherField->add_subfields('7'=>$s7);
					}
				}
				foreach(@nines)
				{
					my $looking = $_;
					my $found = 0;
					foreach(@otherNines)
					{
						if($looking eq $_)
						{
							$found=1;
						}
					}					
					if($found==0 && $ind2 eq '0')
					{
						$otherField->add_subfields('9' => $looking);
					}
				}
				if($ind2 ne '0')
				{
					$thisField->delete_subfields('9');
					$thisField->delete_subfields('z');
				}
				
				$urls{$u} = $otherField;
			}
		}
		
	}
	
	my $finalCount = scalar keys %urls;
	if($original856 != $finalCount)
	{
		$log->addLine("There was $original856 and now there are $finalCount");
	}
	
	my $dump1=Dumper(\%urls);
	my @remove = $marc->field('856');
	#$log->addLine("Removing ".$#remove." 856 records");
	$marc->delete_fields(@remove);


	while ((my $internal, my $mvalue ) = each(%urls))
	{	
		$marc->insert_grouped_field( $mvalue );
	}
	return $marc;
}

sub convertMARCtoXML
{
	my $marc = @_[0];
	my $thisXML =  decode_utf8($marc->as_xml());	
	#this code is borrowed from marc2bre.pl
	$thisXML =~ s/\n//sog;
	$thisXML =~ s/^<\?xml.+\?\s*>//go;
	$thisXML =~ s/>\s+</></go;
	$thisXML =~ s/\p{Cc}//go;
	$thisXML = OpenILS::Application::AppUtils->entityize($thisXML);
	$thisXML =~ s/[\x00-\x1f]//go;
	$thisXML =~ s/^\s+//;
	$thisXML =~ s/\s+$//;
	$thisXML =~ s/<record><leader>/<leader>/;
	$thisXML =~ s/<collection/<record/;	
	$thisXML =~ s/<\/record><\/collection>/<\/record>/;
	#end code
	return $thisXML;
}

sub createNewJob
{
	my $status = @_[0];
	my $query = "INSERT INTO seekdestroy.job(status) values('$status')";
	my $results = $dbHandler->update($query);
	if($results)
	{
		$query = "SELECT max( ID ) FROM seekdestroy.job";
		my @results = @{$dbHandler->query($query)};
		foreach(@results)
		{
			my $row = $_;
			my @row = @{$row};
			$jobid = @row[0];
			return @row[0];
		}
	}
	return -1;
}

sub getFingerprints
{
	my $marcRecord = @_[0];
	my $marc = populate_marc($marcRecord);	
	my %marc = %{normalize_marc($marc)};    
	my %fingerprints;
    $fingerprints{baseline} = join("\t", 
	  $marc{item_form}, $marc{date1}, $marc{record_type},
	  $marc{bib_lvl}, $marc{title}, $marc{author} ? $marc{author} : '');
	$fingerprints{item_form} = $marc{item_form};
	$fingerprints{date1} = $marc{date1};
	$fingerprints{record_type} = $marc{record_type};
	$fingerprints{bib_lvl} = $marc{bib_lvl};
	$fingerprints{title} = $marc{title};
	$fingerprints{author} = $marc{author};
	$fingerprints{audioformat} = $marc{audioformat};
	$fingerprints{videoformat} = $marc{videoformat};
	#print Dumper(%fingerprints);
	return \%fingerprints;
}

#This is borrowed from fingerprinter and altered a bit for the item form
sub populate_marc {
    my $record = @_[0];
    my %marc = (); $marc{isbns} = [];

    # record_type, bib_lvl
    $marc{record_type} = substr($record->leader, 6, 1);
    $marc{bib_lvl}     = substr($record->leader, 7, 1);

    # date1, date2
    my $my_008 = $record->field('008');
	my @my_007 = $record->field('007');
	my $my_006 = $record->field('006');
    $marc{tag008} = $my_008->as_string() if ($my_008);
    if (defined $marc{tag008}) {
        unless (length $marc{tag008} == 40) {
            $marc{tag008} = $marc{tag008} . ('|' x (40 - length($marc{tag008})));
#            print XF ">> Short 008 padded to ",length($marc{tag008})," at rec $count\n";
        }
        $marc{date1} = substr($marc{tag008},7,4) if ($marc{tag008});
        $marc{date2} = substr($marc{tag008},11,4) if ($marc{tag008}); # UNUSED
    }
    unless ($marc{date1} and $marc{date1} =~ /\d{4}/) {
        my $my_260 = $record->field('260');
        if ($my_260 and $my_260->subfield('c')) {
            my $date1 = $my_260->subfield('c');
            $date1 =~ s/\D//g;
            if (defined $date1 and $date1 =~ /\d{4}/) {
                $marc{date1} = $date1;
                $marc{fudgedate} = 1;
 #               print XF ">> using 260c as date1 at rec $count\n";
            }
        }
    }	
	$marc{tag006} = $my_006->as_string() if ($my_006);
	$marc{tag007} = \@my_007 if (@my_007);
	$marc{audioformat}='';
	$marc{videoformat}='';
	foreach(@my_007)
	{
		if(substr($_->data(),0,1) eq 's' && $marc{audioformat} eq '')
		{
			$marc{audioformat} = substr($_->data(),3,1) unless (length $_->data() < 4);
		}
		elsif(substr($_->data(),0,1) eq 'v' && $marc{videoformat} eq '')
		{
			$marc{videoformat} = substr($_->data(),4,1) unless (length $_->data() < 5);
		}
	}
	#print "$marc{audioformat}\n";
	#print "$marc{videoformat}\n";
	
    # item_form
    if ( $marc{record_type} =~ /[gkroef]/ ) { # MAP, VIS
        $marc{item_form} = substr($marc{tag008},29,1) if ($marc{tag008} && (length $marc{tag008} > 29 ));
    } else {
        $marc{item_form} = substr($marc{tag008},23,1) if ($marc{tag008} && (length $marc{tag008} > 23 ));
    }	
	#fall through to 006 if 008 doesn't have info for item form
	if ($marc{item_form} eq '|')
	{
		$marc{item_form} = substr($marc{tag006},6,1) if ($marc{tag006} && (length $marc{tag006} > 6 ));
	}	

    # isbns
    my @isbns = $record->field('020') if $record->field('020');
    push @isbns, $record->field('024') if $record->field('024');
    for my $f ( @isbns ) {
        push @{ $marc{isbns} }, $1 if ( defined $f->subfield('a') and
                                        $f->subfield('a')=~/(\S+)/ );
    }

    # author
    for my $rec_field (100, 110, 111) {
        if ($record->field($rec_field)) {
            $marc{author} = $record->field($rec_field)->subfield('a');
            last;
        }
    }

    # oclc
    $marc{oclc} = [];
    push @{ $marc{oclc} }, $record->field('001')->as_string()
      if ($record->field('001') and $record->field('003') and
          $record->field('003')->as_string() =~ /OCo{0,1}LC/);
    for ($record->field('035')) {
        my $oclc = $_->subfield('a');
        push @{ $marc{oclc} }, $oclc
          if (defined $oclc and $oclc =~ /\(OCoLC\)/ and $oclc =~/([0-9]+)/);
    }

    if ($record->field('999')) {
        my $koha_bib_id = $record->field('999')->subfield('c');
        $marc{koha_bib_id} = $koha_bib_id if defined $koha_bib_id and $koha_bib_id =~ /^\d+$/;
    }

    # "Accompanying material" and check for "copy" (300)
    if ($record->field('300')) {
        $marc{accomp} = $record->field('300')->subfield('e');
        $marc{tag300a} = $record->field('300')->subfield('a');
    }

    # issn, lccn, title, desc, pages, pub, pubyear, edition
    $marc{lccn} = $record->field('010')->subfield('a') if $record->field('010');
    $marc{issn} = $record->field('022')->subfield('a') if $record->field('022');
    $marc{desc} = $record->field('300')->subfield('a') if $record->field('300');
    $marc{pages} = $1 if (defined $marc{desc} and $marc{desc} =~ /(\d+)/);
    $marc{title} = $record->field('245')->subfield('a')
      if $record->field('245');
   
    $marc{edition} = $record->field('250')->subfield('a')
      if $record->field('250');
    if ($record->field('260')) {
        $marc{publisher} = $record->field('260')->subfield('b');
        $marc{pubyear} = $record->field('260')->subfield('c');
        $marc{pubyear} =
          (defined $marc{pubyear} and $marc{pubyear} =~ /(\d{4})/) ? $1 : '';
    }
	#print Dumper(%marc);
    return \%marc;
}

sub normalize_marc {
    my ($marc) = @_;

    $marc->{record_type }= 'a' if ($marc->{record_type} eq ' ');
    if ($marc->{title}) {
        $marc->{title} = NFD($marc->{title});
        $marc->{title} =~ s/[\x{80}-\x{ffff}]//go;
        $marc->{title} = lc($marc->{title});
        $marc->{title} =~ s/\W+$//go;
    }
    if ($marc->{author}) {
        $marc->{author} = NFD($marc->{author});
        $marc->{author} =~ s/[\x{80}-\x{ffff}]//go;
        $marc->{author} = lc($marc->{author});
        $marc->{author} =~ s/\W+$//go;
        if ($marc->{author} =~ /^(\w+)/) {
            $marc->{author} = $1;
        }
    }
    if ($marc->{publisher}) {
        $marc->{publisher} = NFD($marc->{publisher});
        $marc->{publisher} =~ s/[\x{80}-\x{ffff}]//go;
        $marc->{publisher} = lc($marc->{publisher});
        $marc->{publisher} =~ s/\W+$//go;
        if ($marc->{publisher} =~ /^(\w+)/) {
            $marc->{publisher} = $1;
        }
    }
    return $marc;
}

sub marc_isvalid {
    my ($marc) = @_;
    return 1 if ($marc->{item_form} and ($marc->{date1} =~ /\d{4}/) and
                 $marc->{record_type} and $marc->{bib_lvl} and $marc->{title});
    return 0;
}

sub setupSchema
{
	my $query = "DROP SCHEMA seekdestroy CASCADE";
	#$dbHandler->update($query);
	my $query = "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'seekdestroy'";
	my @results = @{$dbHandler->query($query)};
	if($#results==-1)
	{
		$query = "CREATE SCHEMA seekdestroy";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.job
		(
		id bigserial NOT NULL,
		start_time timestamp with time zone NOT NULL DEFAULT now(),
		last_update_time timestamp with time zone NOT NULL DEFAULT now(),
		status text default 'processing',	
		current_action text,
		current_action_num bigint default 0,
		CONSTRAINT job_pkey PRIMARY KEY (id)
		  )";		  
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.bib_score(
		id serial,
		record bigint,
		score bigint,
		improved_score_amount bigint default 0,
		score_time timestamp default now(), 		
		electronic bigint,
		audiobook_score bigint,
		largeprint_score bigint,
		video_score bigint,		
		microfilm_score bigint,
		microfiche_score bigint,
		music_score bigint,
		playaway_score bigint,
		winning_score text,
		winning_score_score bigint,
		winning_score_distance bigint,
		second_place_score text,
		item_form text,
		date1 text,
		record_type text,
		bib_lvl text,
		title text,
		author text,
		sd_fingerprint text,
		audioformat text,
		videoformat text,
		circ_mods text DEFAULT ''::text,
		call_labels text DEFAULT ''::text,
		copy_locations text DEFAULT ''::text,
		opac_icon text DEFAULT ''::text,
		eg_fingerprint text
		)";		
		$dbHandler->update($query);		
		$query = "CREATE TABLE seekdestroy.bib_merge(
		id serial,
		leadbib bigint,
		subbib bigint,
		change_time timestamp default now(),
		job  bigint NOT NULL,
		CONSTRAINT bib_merge_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.undedupe(
		id serial,
		oldleadbib bigint,
		undeletedbib bigint,
		undeletedbib_electronic_score bigint,
		undeletedbib_marc_score bigint,
		moved_call_number bigint,
		change_time timestamp default now(),
		job  bigint NOT NULL,
		CONSTRAINT undedupe_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.bib_match(
		id serial,
		bib1 bigint,
		bib2 bigint,
		match_reason text,
		merged boolean default false,
		has_holds boolean default false,
		job  bigint NOT NULL,
		CONSTRAINT bib_match_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.bib_item_circ_mods(
		id serial,
		record bigint,
		circ_modifier text,
		different_circs bigint,
		job  bigint NOT NULL,
		CONSTRAINT bib_item_circ_mods_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$query = "CREATE TABLE seekdestroy.bib_item_call_labels(
		id serial,
		record bigint,
		call_label text,
		different_call_labels bigint,
		job  bigint NOT NULL,
		CONSTRAINT bib_item_call_labels_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$query = "CREATE TABLE seekdestroy.bib_item_locations(
		id serial,
		record bigint,
		location text,
		different_locations bigint,
		job  bigint NOT NULL,
		CONSTRAINT bib_item_locations_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.problem_bibs(
		id serial,
		record bigint,
		problem text,
		extra text,
		job  bigint NOT NULL,
		CONSTRAINT problem_bibs_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.call_number_move(
		id serial,
		call_number bigint,
		frombib bigint,
		tobib bigint,
		extra text,
		success boolean default true,
		change_time timestamp default now(),
		job  bigint NOT NULL,
		CONSTRAINT call_number_move_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.copy_move(
		id serial,
		copy bigint,
		fromcall bigint,
		tocall bigint,
		extra text,
		change_time timestamp default now(),
		job  bigint NOT NULL,
		CONSTRAINT copy_move_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
		$query = "CREATE TABLE seekdestroy.bib_marc_update(
		id serial,
		record bigint,
		prev_marc text,
		changed_marc text,
		new_record boolean NOT NULL DEFAULT false,
		change_time timestamp default now(),
		extra text,
		job  bigint NOT NULL,
		CONSTRAINT bib_marc_update_fkey FOREIGN KEY (job)
		REFERENCES seekdestroy.job (id) MATCH SIMPLE)";
		$dbHandler->update($query);
	}
}

sub updateJob
{
	my $status = @_[0];
	my $action = @_[1];
	my $query = "UPDATE seekdestroy.job SET last_update_time=now(),status='$status', CURRENT_ACTION_NUM = CURRENT_ACTION_NUM+1,current_action='$action' where id=$jobid";
	my $results = $dbHandler->update($query);
	return $results;
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

 
 