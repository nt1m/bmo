#!/usr/bin/env perl

# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.
#
# Usage secbugsreport.pl YYYY MM DD HH MM SS +|-ZZZZ
#  e.g. secbugsreport.pl $(date +'%Y %m %d %H %M %S %z')

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5);

use Bugzilla;
use Bugzilla::Component;
use Bugzilla::Constants;
use Bugzilla::Error;
use Bugzilla::Mailer;
use Bugzilla::Report::SecurityRisk;

use DateTime;
use URI;
use JSON::MaybeXS;
use Mojo::File qw(path);
use Data::Dumper;
use Types::Standard qw(Int);

BEGIN { Bugzilla->extensions }
Bugzilla->usage_mode(USAGE_MODE_CMDLINE);

my ($year, $month, $day, $hours, $minutes, $seconds, $time_zone_offset) = @ARGV;

exit 0 unless Bugzilla->params->{report_secbugs_active};
exit 0
  unless Int->check($year)
  && Int->check($month)
  && Int->check($day)
  && Int->check($hours)
  && Int->check($minutes)
  && Int->check($seconds);

my $html;
my $template = Bugzilla->template();
my $end_date = DateTime->new(
  year      => $year,
  month     => $month,
  day       => $day,
  hour      => $hours,
  minute    => $minutes,
  second    => $seconds,
  time_zone => $time_zone_offset
);
$end_date->set_time_zone('UTC');

my $start_date   = $end_date->clone()->subtract(months => 12);
my $report_week  = $end_date->ymd('-');
my $teams        = decode_json(Bugzilla->params->{report_secbugs_teams});
my $sec_keywords = ['sec-critical', 'sec-high'];
my $report       = Bugzilla::Report::SecurityRisk->new(
  start_date   => $start_date,
  end_date     => $end_date,
  teams        => $teams,
  sec_keywords => $sec_keywords,
  very_old_days => 45
);

my $bugs_by_team = $report->results->[-1]->{bugs_by_team};
my @sorted_team_names = sort { ## no critic qw(BuiltinFunctions::ProhibitReverseSortBlock
  @{$bugs_by_team->{$b}->{open}} <=> @{$bugs_by_team->{$a}->{open}} ## no critic qw(Freenode::DollarAB)
    || $a cmp $b
} keys %$teams;

my $vars = {
  urlbase            => Bugzilla->localconfig->urlbase,
  report_week        => $report_week,
  teams              => \@sorted_team_names,
  sec_keywords       => $sec_keywords,
  results            => $report->results,
  deltas             => $report->deltas,
  missing_products   => $report->missing_products,
  missing_components => $report->missing_components,
  very_old_days      => $report->very_old_days,
  build_bugs_link    => \&build_bugs_link,
};

$template->process('reports/email/security-risk.html.tmpl', $vars, \$html)
  or ThrowTemplateError($template->error());

# For now, only send HTML email.
my @parts = (
  Email::MIME->create(
    attributes => {
      content_type => 'text/html',
      charset      => 'UTF-8',
      encoding     => 'quoted-printable',
    },
    body_str => $html,
  ),
  map {
    Email::MIME->create(
      header_str => ['Content-ID' => "<$_.png>",],
      attributes => {
        filename     => "$_.png",
        charset      => 'UTF-8',
        content_type => 'image/png',
        disposition  => 'inline',
        name         => "$_.png",
        encoding     => 'base64',
      },
      body => $report->graphs->{$_}->slurp,
    )
  } sort { $a cmp $b } keys %{$report->graphs}
);

my $email = Email::MIME->create(
  header_str => [
    From              => Bugzilla->params->{'mailfrom'},
    To                => Bugzilla->params->{report_secbugs_emails},
    Subject           => "Security Bugs Report for $report_week",
    'X-Bugzilla-Type' => 'admin',
  ],
  parts => [@parts],
);

MessageToMTA($email);

my $report_dump_file = path(bz_locations->{datadir}, "$year-$month-$day.dump");
$report_dump_file->spurt(Dumper($report));

sub build_bugs_link {
  my ($arr, $product) = @_;
  my $uri = URI->new(Bugzilla->localconfig->urlbase . 'buglist.cgi');
  $uri->query_param(bug_id => (join ',', @$arr));
  $uri->query_param(product => $product) if $product;
  return $uri->as_string;
}
