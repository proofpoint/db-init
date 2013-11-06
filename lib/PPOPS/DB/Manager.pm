#!perl
# /* Copyright 2013 Proofpoint, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# */

package PPOPS::DB::Manager;

use strict;
use DBI;
use Carp;
use Data::Dumper;

sub new {
   my ($class, $opt) = @_;

   my $defopt = {
      'driver' => 'mysql',
      'user' => 'root',
      'password' => '',
      'debug' => 0,
   };

   for my $key (keys %$defopt) {
      $opt->{$key} ||= $defopt->{$key};
   }

   my $self = bless({}, $class);

   $self->{'opt'} = $opt;

   eval {
      $self->{'dbh'} = DBI->connect($self->dsn(),
                                    $self->{'opt'}->{'user'},
                                    $self->{'opt'}->{'password'},
                                    { RaiseError => 1 });
   };
   if ($@) {
      my $msg = $@;
      $msg =~ s/ at .*//;
      croak "Couldn't connect to " . $self->dsn() . " as $self->{'opt'}->{'user'}: $msg";
   }

   return $self;
}

sub dsn {
   my ($self) = @_;

   join(':', 'dbi', $self->{'opt'}->{'driver'}, ':');
}

sub exists_db {
   my ($self, $db) = @_;
   my %db;
   
   my $st = 'SHOW DATABASES';
   my @rows = $self->_query($st => "Couldn't list databases");
   for my $row (@rows) {
      $self->dbg("identified database $row->[0]");
      $db{$row->[0]} = $row->[0];
   }

   return 1 if $db{$db};
   return 0;
}

sub create_db {
   my ($self, $db) = @_;

   # SMELL: unsanitized input
   my $st = "CREATE DATABASE $db";
   $self->_do($st => "Couldn't create database $db");

   return $db;
}

sub ensure_db {
   my ($self, $db) = @_;

   if ($self->exists_db($db)) {
      return 0;
   } else {
      $self->create_db($db);
   }
}

sub exists_user {
   my ($self, $user) = @_;

   my $st = 'SELECT user, host FROM mysql.user WHERE user = ?';
   my @rows = $self->_query($st => "Couldn't determine existence of $user",
       $user);
   if (scalar(@rows)) {
      return 1;
   } else {
      return 0;
   }
}

sub create_user {
   my ($self, $user, $attr) = @_;

   # SMELL: unsanitized input
   croak "Password must be provided for user $user" unless
       ($attr->{'password'});
   my $pwd = $attr->{'password'};
   my $st = "CREATE user $user\@'\%' IDENTIFIED BY '$pwd'";
   $self->_do($st => "Couldn't create user $user\@%");
   $st = "CREATE user $user\@localhost IDENTIFIED BY '$pwd'";
   $self->_do($st => "Couldn't create user $user\@localhost");

   if ($attr->{'grant'}) {
      for my $obj (keys %{$attr->{'grant'}}) {
         my $priv = $attr->{'grant'}->{$obj};
         my $st1 = "GRANT $priv ON $obj TO $user\@'\%'";
         my $st2 = "GRANT $priv ON $obj TO $user\@localhost";
         $self->_do($st1 => "Couldn't execute grant to $user\@'\%'");
         $self->_do($st2 => "Couldn't execute grant to $user\@'\%'");

      }
   }

   return $user;
}

sub ensure_user {
   my ($self, $user, $attr) = @_;

   if ($self->exists_user($user)) {
      return 0;
   } else {
      $self->create_user($user, $attr);
   }
}

sub exists_tab {
   my ($self, $db, $tab) = @_;

   # SMELL: unsanitized input
   $self->{'dbh'}->do("use $db");
   my $st = 'SELECT table_schema, table_name FROM information_schema.tables '
       . 'WHERE table_schema = ? AND table_name = ?';
   my @rows = $self->_query($st => "Couldn't determine existence of $db.$tab",
                            $db, $tab);
   if (scalar(@rows)) {
      return 1;
   } else {
      return 0;
   }
}

sub create_tab {
   my ($self, $db, $tab, @statements) = @_;

   $self->{'dbh'}->do("use $db");
   my $ix = 1;
   for my $st (@statements) {
      $self->_do($st => "Couldn't create table $tab with statement $ix");
      $ix++;
   }

   return "$db.$tab";
}

sub ensure_tab {
   my ($self, $db, $tab, @statements) = @_;

   if ($self->exists_tab($db, $tab)) {
      return 0;
   } else {
      $self->create_tab($db, $tab, @statements);
   }
}

sub _do {
   my ($self, $st, $complaint, @args) = @_;
   my $rv;

   eval {
      my $sth = $self->{'dbh'}->prepare($st);
      $rv = $sth->execute(@args) unless $self->{'opt'}->{'dry-run'};
      $sth->finish();
   };
   if ($@) {
      my $msg = $@;
      $msg =~ s/ at.*//;
      croak "$complaint (in " . $self->dsn() . "): $msg";
   }

   return $rv;
}

sub _query {
   my ($self, $st, $complaint, @args) = @_;
   my @rows = ( );

   $self->dbg("_query: $st -> else $complaint (" . scalar(@args) . " args)");

   eval {
      my $sth = $self->{'dbh'}->prepare($st);
      $sth->execute(@args);
      while (my @row = $sth->fetchrow_array()) {
         $self->dbg("row: " . ddump([ @row ]));
         push(@rows, [ @row ]);
      }
      $sth->finish();
   };
   if ($@) {
      my $msg = $@;
      $msg =~ s/ at.*//;
      croak "$complaint (in " . $self->dsn() . "): $msg";
   }

   return @rows;
}

sub dbg {
   my ($self, @msg) = @_;

   print "DBG(" . ref($self) . "): " .
       join("\nDBG(" . ref($self) . "):    ", @msg),
       "\n" if $self->{'opt'}->{'debug'} > 1;
}

sub ddump {
   my $v = 'v0';
   Data::Dumper->new([@_], [map {$v++} @_])->Terse(1)->Indent(0)->Dump;
}

1;
