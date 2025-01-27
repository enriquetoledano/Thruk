package Thruk::Controller::Rest::V1::cluster;

use strict;
use warnings;
use Thruk::Controller::rest_v1;

=head1 NAME

Thruk::Controller::Rest::V1::cluster - Cluster rest interface version 1

=head1 DESCRIPTION

Thruk Controller

=head1 METHODS

=cut

##########################################################
# REST PATH: GET /thruk/cluster
# lists cluster nodes
Thruk::Controller::rest_v1::register_rest_path_v1('GET', qr%^/thruk/cluster$%mx, \&_rest_get_thruk_cluster, ['authorized_for_system_information']);
sub _rest_get_thruk_cluster {
    my($c) = @_;
    return($c->cluster->{'nodes'});
}

##########################################################
# REST PATH: GET /thruk/cluster/heartbeat
# redirects to POST method
# REST PATH: POST /thruk/cluster/heartbeat
# send cluster heartbeat to all other nodes
Thruk::Controller::rest_v1::register_rest_path_v1('POST', qr%^/thruk/cluster/heartbeat$%mx, \&_rest_get_thruk_cluster_heartbeat, ['authorized_for_system_commands']);
Thruk::Controller::rest_v1::register_rest_path_v1('GET', qr%^/thruk/cluster/heartbeat$%mx, \&_rest_get_thruk_cluster_heartbeat, ['authorized_for_system_commands']);
sub _rest_get_thruk_cluster_heartbeat {
    my($c) = @_;
    return({ 'message' => 'cluster disabled', 'description' => 'this is a single node installation and not clustered', code => 501 }) unless $c->cluster->is_clustered();
    if($c->req->method() eq 'GET') {
        return({ 'message' => 'bad request', description => 'POST method required', code => 400 });
    }

    # cron mode: cron starts heartbeat every minute, if heartbeat interval is less than a minute, do multiple checks and sleep meanwhile
    if($ENV{'THRUK_CRON'} && $c->config->{'cluster_heartbeat_interval'} > 0 && $c->config->{'cluster_heartbeat_interval'} < 60) {
        local $ENV{'THRUK_CRON'} = undef;
        my $start = time();
        while(time() - $start < 60) {
            my $now = time();
            _rest_get_thruk_cluster_heartbeat($c);
            sleep($c->config->{'cluster_heartbeat_interval'} - (time() - $now));
        }
        return;
    }
    local $ENV{'THRUK_SKIP_CLUSTER'} = 0;
    $c->cluster->load_statefile();
    for my $n (@{$c->cluster->{'nodes'}}) {
        next if $c->cluster->is_it_me($n);
        my $res = $c->cluster->run_cluster($n, "Thruk::Utils::Cluster::pong", [$c, $n->{'node_id'}, $n->{'node_url'}])->[0];
        if(!$res) {
            next;
        }
        if($res->{'node_id'} ne $n->{'node_id'}) {
            $c->log->error(sprintf("cluster mixup, got answer from node %s but expected %s for url %s", $res->{'node_id'}, $n->{'node_id'}, $n->{'node_url'}));
            next;
        }
    }
    $c->cluster->check_stale_pids();
    return({ 'message' => 'heartbeat send' });
}

##########################################################
# REST PATH: GET /thruk/cluster/<id>
# return cluster state for given node.
#
# See `/thruk/cluster/` for the description of the attributes.
Thruk::Controller::rest_v1::register_rest_path_v1('GET', qr%^/thruk/cluster/([^/]+)$%mx, \&_rest_get_thruk_cluster_node_by_id, ['authorized_for_system_information']);
sub _rest_get_thruk_cluster_node_by_id {
    my($c, $path_info, $node_id) = @_;
    ($node_id) = @{$c->cluster->expand_node_ids($node_id)};
    return($c->cluster->{'nodes_by_id'}->{$node_id}) if $node_id;
    return({ 'message' => 'no such cluster node', code => 404 });
}

##########################################################

1;
