package Thruk::Utils::Cluster;

=head1 NAME

Thruk::Utils::Cluster - Cluster Utilities Collection for Thruk

=head1 DESCRIPTION

Cluster Utilities Collection for Thruk

=cut

use strict;
use warnings;
use Thruk::Utils;
use Thruk::Utils::IO;
use Thruk::Backend::Provider::HTTP;
use Time::HiRes qw/gettimeofday tv_interval/;
use Digest::MD5 qw(md5_hex);
use Carp qw/confess/;
use Data::Dumper qw/Dumper/;

my $context;

##########################################################

=head1 METHODS

=head2 new

create new cluster instance

=cut
sub new {
    my($class, $thruk) = @_;
    my $self = {
        nodes        => [],
        nodes_by_url => {},
        nodes_by_id  => {},
        config       => $thruk->config,
        statefile    => $thruk->config->{'var_path'}.'/cluster/nodes',
        localstate   => $thruk->config->{'tmp_path'}.'/cluster/nodes',
    };
    bless $self, $class;

    Thruk::Utils::IO::mkdir_r($thruk->config->{'var_path'}.'/cluster');
    Thruk::Utils::IO::mkdir_r($thruk->config->{'tmp_path'}.'/cluster');

    if(scalar @{$self->{'config'}->{'cluster_nodes'}} > 1) {
        $self->{'cluster_nodes_map'} = {};
        for my $url (@{$self->{'config'}->{'cluster_nodes'}}) {
            $self->{'cluster_nodes_map'}->{$url} = $url;
        }
    }

    return $self;
}

##########################################################

=head2 load_statefile

load statefile and fill node structures

=cut
sub load_statefile {
    my($self, $nodes) = @_;
    my $c = $Thruk::Utils::Cluster::context;
    $c->stats->profile(begin => "cluster::load_statefile") if $c;
    $self->{'nodes'}        = [];
    $self->{'nodes_by_id'}  = {};
    $self->{'nodes_by_url'} = {};

    if(!$nodes) {
        $nodes = Thruk::Utils::IO::json_lock_retrieve($self->{'statefile'}) || {};
    }

    # remove unknown and dummy nodes first
    for my $key (sort keys %{$nodes}) {
        if(!defined $nodes->{$key}->{'node_url'} || $key =~ m/^dummy/mx) {
            delete $nodes->{$key};
            Thruk::Utils::IO::json_lock_patch($self->{'statefile'}, {
                $key => undef,
            },1);
        }
    }

    # when using fixed nodes, verify all of them are available in $nodes
    if(scalar @{$self->{'config'}->{'cluster_nodes'}} > 1 && scalar @{$self->{'config'}->{'cluster_nodes'}} != scalar keys %{$nodes}) {
        # add dummy node(s)
        for my $x (1..(scalar @{$self->{'config'}->{'cluster_nodes'}} - scalar keys %{$nodes})) {
            $nodes->{"dummy".$x} = {
                node_url => "",
                node_id  => "dummy".$x,
            };
        }
    }

    my $now = time();
    for my $key (sort keys %{$nodes}) {
        my $n = $nodes->{$key};
        $n->{'last_update'} =  0 unless $n->{'last_update'};
        # no contact in last x seconds, remove it completely from cluster
        if($n->{'last_update'} < $now - $c->config->{'cluster_node_stale_timeout'} && $key ne $Thruk::NODE_ID) {
            $self->unregister($key);
            next:
        }
        # set some defaults
        $n->{'last_contact'}  =  0 unless $n->{'last_contact'};
        $n->{'last_error'}    = '' unless $n->{'last_error'};
        $n->{'response_time'} = '' unless defined $n->{'response_time'};
        $n->{'version'}       = '' unless defined $n->{'version'};
        $n->{'branch'}        = '' unless defined $n->{'branch'};

        # add node to store
        push @{$self->{'nodes'}}, $n;
        $self->{'nodes_by_id'}->{$key} = $n;
    }

    # assign remaining cluster urls to nodes without url
    if(scalar @{$self->{'config'}->{'cluster_nodes'}} > 1) {
        for my $key (sort keys %{$nodes}) {
            my $n = $nodes->{$key};
            next if $n->{'node_url'};
            # find first unused cluster_node url
            my $next_url = "";
            for my $url (sort keys %{$self->{'cluster_nodes_map'}}) {
                my $found = 0;
                for my $key (sort keys %{$nodes}) {
                    if($nodes->{$key}->{'node_url'} eq $self->{'cluster_nodes_map'}->{$url}) {
                        $found = 1;
                        last;
                    }
                }
                if(!$found) {
                    $next_url = $url;
                    last;
                }
            }
            $self->{'cluster_nodes_map'}->{$next_url} = $self->_replace_url_macros($next_url);
            $n->{'node_url'} = $self->{'cluster_nodes_map'}->{$next_url};
        }
    }

    for my $key (sort keys %{$nodes}) {
        my $n = $nodes->{$key};
        $self->{'nodes_by_url'}->{$n->{'node_url'}} = $n;
    }

    $c->stats->profile(end => "cluster::load_statefile") if $c;
    return $nodes;
}

##########################################################

=head2 register

registers this cluster node in the cluster statefile

=cut
sub register {
    my($self, $c) = @_;
    $Thruk::Utils::Cluster::context = $c;
    my $now = time();
    $self->load_statefile();
    my $old_url = $self->{'nodes_by_id'}->{$Thruk::NODE_ID}->{'node_url'} || '';
    my $localstate = Thruk::Utils::IO::json_lock_patch($self->{'localstate'}, {
        pids => { $$ => $now },
    },1);
    $self->check_stale_pids($localstate);
    Thruk::Utils::IO::json_lock_patch($self->{'statefile'}, {
        $Thruk::NODE_ID => {
            node_id      => $Thruk::NODE_ID,
            node_url     => $self->_build_node_url() || $old_url || '',
            hostname     => $Thruk::HOSTNAME,
            last_update  => $now,
            pids         => scalar keys %{$localstate->{'pids'}},
        },
    }, 1);
    return;
}

##########################################################

=head2 unregister

removes ourself from the cluster statefile

=cut
sub unregister {
    my($self, $nodeid) = @_;
    return unless -s $self->{'statefile'};
    $nodeid = $Thruk::NODE_ID unless $nodeid;
    if($nodeid eq $Thruk::NODE_ID) {
        my $localstate = Thruk::Utils::IO::json_lock_patch($self->{'localstate'}, { pids => { $$ => undef }},1);
        Thruk::Utils::IO::json_lock_patch($self->{'statefile'}, {
            $Thruk::NODE_ID => {
                last_update => time(),
                pids        => scalar keys %{$localstate->{'pids'}},
            },
        }, 1);
    } else {
        # do not completely unregister a node if using fixed nodes
        return if scalar @{$self->{'config'}->{'cluster_nodes'}} > 1;

        Thruk::Utils::IO::json_lock_patch($self->{'statefile'}, {
            $nodeid => undef,
        },1);
    }
    return;
}

##########################################################

=head2 refresh

refresh this cluster node in the cluster statefile

=cut
sub refresh {
    my($self) = @_;
    my $localstate = Thruk::Utils::IO::json_lock_patch($self->{'localstate'}, {
        pids => { $$ => time() },
    }, 1);
    if(!$self->{'nodes_by_id'}->{$Thruk::NODE_ID}->{'last_update'} || $self->{'nodes_by_id'}->{$Thruk::NODE_ID}->{'last_update'} < time() - (5+int(rand(20)))) {
        my $state = Thruk::Utils::IO::json_lock_patch($self->{'statefile'}, {
            $Thruk::NODE_ID => {
                last_update => time(),
                pids        => scalar keys %{$localstate->{'pids'}},
            },
        }, 1);
        $self->load_statefile($state);
    }
    return;
}

##########################################################

=head2 is_clustered

return 1 if a cluster is configured

=cut
sub is_clustered {
    my($self) = @_;
    return 0 if !$self->{'config'}->{'cluster_enabled'};
    return 1 if scalar keys %{$self->{nodes_by_url}} > 1;
    return 1 if scalar @{$self->{'config'}->{'cluster_nodes'}} > 1;
    return 0;
}

##########################################################

=head2 node_ids

return list of node ids

=cut
sub node_ids {
    my($self) = @_;
    return([keys %{$self->{nodes_by_id}}]);
}

##########################################################

=head2 run_cluster

run something on our cluster

    - type: can be
        - 'once'      runs job on current node unless it is in progress already
        - 'all'       runs job on all nodes
        - 'others'    runs job on all other nodes
        - <node url>  runs job on given node[s]
    - sub: class / sub name
    - args: arguments

returns 0 if no cluster is in use and caller can continue locally
returns 1 if a 'once' job runs somewhere already
returns list of results for each specified node

=cut
sub run_cluster {
    my($self, $type, $sub, $args) = @_;
    return 0 unless $self->is_clustered();
    return 0 if $ENV{'THRUK_SKIP_CLUSTER'};
    local $ENV{'THRUK_SKIP_CLUSTER'} = 1;

    my $c = $Thruk::Utils::Cluster::context;

    my $nodes = Thruk::Utils::list($type);
    if($type eq 'all' || $type eq 'others') {
        $nodes = $self->{'nodes'};
    }

    if($type eq 'once') {
        return 0 unless $ENV{'THRUK_CRON'};
        confess("no args supported") if $args;
        # check if cmd is already running
        my $digest = md5_hex(sprintf("%s-%s-%s", POSIX::strftime("%Y-%m-%d %H:%M", localtime()), $sub, Dumper($args)));
        my $jobs_path = $c->config->{'var_path'}.'/cluster/jobs';
        Thruk::Utils::IO::mkdir_r($jobs_path);
        Thruk::Utils::IO::write($jobs_path.'/'.$digest, $Thruk::NODE_ID."\n", undef, 1);
        my $lock = [split(/\n/mx, Thruk::Utils::IO::read($jobs_path.'/'.$digest))]->[0];
        if($lock ne $Thruk::NODE_ID) {
            $c->log->debug(sprintf("run_cluster once: %s running on %s already", $sub, $lock));
            return(1);
        }
        $self->_cleanup_jobs_folder();
        $c->log->debug(sprintf("run_cluster once: %s starting on %s", $sub, $lock));

        # continue and run on this node
        return(0);
    }

    # expand nodeurls/ids
    my @nodeids = @{$self->expand_node_ids(@{$nodes})};

    # if request contains only a single node and thats our own id, simply pass, no need to run that through extra web request
    if(scalar @nodeids == 1 && $self->is_it_me($nodeids[0])) {
        return(0);
    }

    # replace $c in args with placeholder
    $args = Thruk::Utils::encode_arg_refs($args);

    # run function on each cluster node
    my $res = [];
    my $statefileupdate = {};
    for my $n (@nodeids) {
        next unless $self->{'nodes_by_id'}->{$n};
        next if($type eq 'others' && $self->is_it_me($n));
        $c->log->debug(sprintf("%s trying on %s", $sub, $n));
        my $node = $self->{'nodes_by_id'}->{$n};
        my $http = Thruk::Backend::Provider::HTTP->new({ peer => $node->{'node_url'}, auth => $c->config->{'secret_key'} }, undef, undef, undef, undef, $c->config);
        my $t1   = [gettimeofday];
        my $r;
        eval {
            $r = $http->_req($sub, $args, undef, undef, 1);
        };
        my $elapsed = tv_interval($t1);
        if($@) {
            $c->log->error(sprintf("%s failed on %s: %s", $sub, $n, $@));
            if($n !~ m/^dummy/mx) {
                $statefileupdate->{$n} = {
                    last_error => $@,
                };
            }
        } else {
            if($n !~ m/^dummy/mx) {
                if($sub =~ m/Cluster::pong/mx) {
                    $statefileupdate->{$n} = {
                        last_contact  => time(),
                        last_error    => '',
                        response_time => $elapsed,
                        version       => $r->{'version'},
                        branch        => $r->{'branch'},
                    };
                } else {
                    $statefileupdate->{$n} = {
                        last_contact  => time(),
                        last_error    => '',
                    };
                }
            }
        }
        $r = $r->{'output'} if $r;
        if(ref $r eq 'ARRAY' && scalar @{$r} == 1) {
            push @{$res}, $r->[0];
        } else {
            push @{$res}, $r;
        }
    }

    # bulk update statefile
    Thruk::Utils::IO::json_lock_patch($c->cluster->{'statefile'}, $statefileupdate, 1);

    return $res;
}

##########################################################

=head2 kill

  kill($c, $node, $signal, @pids)

cluster aware kill wrapper

=cut
sub kill {
    my($self, $c, $node, $sig, @pids) = @_;
    my $res = $self->run_cluster($node, "Thruk::Utils::Cluster::kill", [$self, $c, $node, $sig, @pids]);
    if(!$res) {
        return(CORE::kill($sig, @pids));
    }
    return($res->[0]);
}

##########################################################

=head2 pong

  pong($c, $node)

return a ping request

=cut
sub pong {
    my($c, $node, $url) = @_;
    if($node ne $Thruk::NODE_ID && $node =~ m/^dummy\d+$/mx) {
        # update our url
        if(!$c->cluster->{'nodes_by_id'}->{$Thruk::NODE_ID}->{'node_url'} || $c->cluster->{'nodes_by_id'}->{$Thruk::NODE_ID}->{'node_url'} ne $url) {
            Thruk::Utils::IO::json_lock_patch($c->cluster->{'statefile'}, {
                $Thruk::NODE_ID => {
                    node_url => $url,
                },
            },1);
        }
    }
    return({
        time    => time(),
        node_id => $node,
    });
}

##########################################################

=head2 is_it_me

  is_it_me($self, $node|$node_id|$node_url)

returns true if this us

=cut
sub is_it_me {
    my($self, $n) = @_;
    if(ref $n eq 'HASH' && $n->{'node_id'} && $n->{'node_id'} eq $Thruk::NODE_ID) {
        return(1);
    }
    if($n eq $Thruk::NODE_ID) {
        return(1);
    }
    if($self->{'nodes_by_url'}->{$n} && $self->{'nodes_by_url'}->{$n}->{'key'} eq $Thruk::NODE_ID) {
        return(1);
    }
    return(0);
}

##########################################################
sub _build_node_url {
    my($self, $hostname) = @_;
    $hostname = $Thruk::HOSTNAME unless $hostname;
    my $url;
    if(scalar @{$self->{'config'}->{'cluster_nodes'}} == 1) {
        $url = $self->{'config'}->{'cluster_nodes'}->[0];
    } else {
        # is there a url in cluster_nodes which matches our hostname?
        for my $tst (@{$self->{'config'}->{'cluster_nodes'}}) {
            if($tst =~ m/\Q$hostname\E/mx) {
                $url = $tst;
                last;
            }
        }
        return "" unless $url;
    }
    my $orig_url = $url;
    $url =~ s%\$hostname\$%$hostname%mxi;
    $url = $self->_replace_url_macros($url);
    $self->{'cluster_nodes_map'}->{$orig_url} = $url;
    return($url);
}

##########################################################
sub _replace_url_macros {
    my($self, $url) = @_;
    my $proto = $self->{'config'}->{'omd_apache_proto'} ? $self->{'config'}->{'omd_apache_proto'} : 'http';
    $url =~ s%\$proto\$%$proto%mxi;
    my $url_prefix = $self->{'config'}->{'url_prefix'};
    $url =~ s%\$url_prefix\$%$url_prefix%mxi;
    $url =~ s%/+%/%gmx;
    $url =~ s%^(https?:/)%$1/%gmx;
    return($url);
}

##########################################################
sub _cleanup_jobs_folder {
    my($self) = @_;
    my $keep = time() - 600;
    my $jobs_path = $self->{'config'}->{'var_path'}.'/cluster/jobs';
    for my $file (glob($jobs_path.'/*')) {
        my @stat = stat($file);
        if($stat[9] && $stat[9] < $keep) {
            unlink($file);
        }
    }
    return;
}

##########################################################

=head2 expand_node_ids

  expand_node_ids($self, @nodes_ids_and_urls)

convert list of node_ids and node_urls to node_ids only.

=cut
sub expand_node_ids {
    my($self, @nodeids) = @_;
    my $expanded = [];
    for my $id (@nodeids) {
        if(ref $id eq 'HASH' && $id->{'node_id'}) {
            push @{$expanded}, $id->{'node_id'};
        }
        elsif($self->{'nodes_by_id'}->{$id}) {
            push @{$expanded}, $id;
        }
        elsif($self->{'nodes_by_url'}->{$id}) {
            push @{$expanded}, $self->{'nodes_by_url'}->{$id}->{'node_id'};
        }
    }
    return($expanded);
}

##########################################################

=head2 update_cron_file

    update_cron_file($c)

update downtimes cron

=cut
sub update_cron_file {
    my($c) = @_;

    my $cron_entries = [];

    if($c->config->{'cluster_enabled'}) {
        # ensure proper cron.log permission
        open(my $fh, '>>', $c->config->{'var_path'}.'/cron.log');
        Thruk::Utils::IO::close($fh, $c->config->{'var_path'}.'/cron.log');
        my $log = sprintf(">/dev/null 2>>%s/cron.log", $c->config->{'var_path'});
        my $cmd = sprintf("cd %s && %s '%s r -m POST /thruk/cluster/heartbeat ' %s",
                                $c->config->{'project_root'},
                                $c->config->{'thruk_shell'},
                                $c->config->{'thruk_bin'},
                                $log,
                        );
        my $time = '* * * * *';
        $cron_entries = [[$time, $cmd]];
    }
    Thruk::Utils::update_cron_file($c, 'cluster', $cron_entries);
    return;
}

##########################################################

=head2 check_stale_pids

    check_stale_pids($self, $localstate)

check for stale pids

=cut
sub check_stale_pids {
    my($self, $localstate) = @_;
    my $node = $self->{'nodes_by_id'}->{$Thruk::NODE_ID};
    return unless $node;
    my $now = time();
    # check for stale pids
    for my $pid (sort keys %{$localstate->{'pids'}}) {
        next if $now - $localstate->{'pids'}->{$pid} < 60; # old check old pids
        if($pid != $$ && CORE::kill($pid, 0) != 1) {
            Thruk::Utils::IO::json_lock_patch($self->{'localstate'}, {
                pids => { $pid => undef },
            },1);
        }
    }
    return;
}

##########################################################

1;
