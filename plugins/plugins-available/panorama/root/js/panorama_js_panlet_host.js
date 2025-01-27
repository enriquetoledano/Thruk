/* Add new downtime menu item */
TP.host_downtime_menu = function() {
    var fields = [{
            fieldLabel: 'Comment',
            xtype:      'textfield',
            name:       'com_data',
            emptyText:  'comment',
            width:      288
        }, {
            fieldLabel: 'Next Check',
            xtype:      'datetimefield',
            name:       'start_time'
        }, {
            fieldLabel: 'End Time',
            xtype:      'datetimefield',
            name:       'end_time'
        }, {
            xtype: 'hidden', name: 'com_author',  value: remote_user
        }, {
            xtype: 'hidden', name: 'fixed',       value: '1'
    }];
    return TP.ext_menu_command('Add', 55, fields);
}

/* Acknowledge menu item */
TP.host_ack_menu = function() {
    var fields = [{
            fieldLabel: 'Comment',
            xtype:      'textfield',
            name:       'com_data',
            emptyText:  'comment',
            width:      288
        }, {
            fieldLabel: 'Sticky Acknowledgement',
            xtype:      'checkbox',
            name:       'sticky_ack'
        }, {
            fieldLabel: 'Send Notification',
            xtype:      'checkbox',
            name:       'send_notification'
        }, {
            fieldLabel: 'Persistent Comment',
            xtype:      'checkbox',
            name:       'persistent'
        }, {
            xtype: 'hidden', name: 'com_author',  value: remote_user
    }];
    var defaults = {
        labelWidth: 140
    };
    return TP.ext_menu_command('Acknowledge', 33, fields, defaults);
}

/* Remove Acknowledge menu item */
TP.host_ack_remove_menu = function() {
    var fields = [{
        fieldLabel: '',
        xtype:      'displayfield',
        value:      'no options needed',
        name:       'display',
        width:      240
    }];
    return TP.ext_menu_command('Remove Acknowledgement', 51, fields);
}

/* Reschedule check menu item */
TP.host_reschedule_menu = function() {
    var fields = [{
        fieldLabel: 'Next Check',
        xtype:      'datetimefield',
        name:       'start_time',
        value:      new Date()
    }];
    return TP.ext_menu_command('Reschedule', 96, fields);
}

/* form submit handler */
TP.cmd_form_handler = function() {
    var menu  = this.up('menu');
    var panel = menu.up('panel').up('panel');
    var tab   = Ext.getCmp(panel.panel_id);
    var form  = this.up('menu').down('form').getForm();
    if(form.isValid()) {
        form.submit({
            success: function(form, action) {
                TP.getResponse(panel, action.response);
                menu.letItClose=true;
                menu.hide();
                panel.manualRefresh();
                TP.refreshAllSitePanel(tab);
             },
             failure: function(form, action) {
                TP.getResponse(panel, action.response);
             },
             waitMsg: 'sending command...'
        });
    }
}

TP.updateExtinfoDetails = function(This, success, response, options) {
    This.loading = false;
    var data  = TP.getResponse(this, response);
    if(data && data.data) {
        var d         = data.data;
        var downtimes = data.downtimes;
        var panel     = this.items.getAt(0);
        TP.log('['+panel.id+'] loaded');
        var statename = this.type == 'host' ? TP.render_host_status(d.state, {}, data) : TP.render_service_status(d.state, {}, data) ;
        panel.getComponent('current_status').update('<div class="extinfostate '+statename.toUpperCase()+'">'+statename.toUpperCase()+'<\/div> (for ' + TP.render_duration('', '', data)+')'+(d.acknowledged?' (<img src="'+url_prefix+'plugins/panorama/images/btn_ack.png" style="vertical-align:text-bottom"> acknowledged)':''));
        panel.getComponent('status_information').update(d.plugin_output+'<br>'+d.long_plugin_output);
        panel.getComponent('perf_data').update(d.perf_data);
        panel.getComponent('cur_attempt').update(d.current_attempt + '/' + d.max_check_attempts);
        panel.getComponent('last_check_time').update(TP.date_format(d.last_check));
        panel.getComponent('check_type').update(d.check_type == 0 ? 'ACTIVE' : 'PASSIVE');
        panel.getComponent('check_latency').update(Number(d.latency).toFixed(3) + ' / ' + Number(d.execution_time).toFixed(3) + ' seconds');
        panel.getComponent('next_check').update(d.next_check ? TP.date_format(d.next_check) : 'N/A');
        panel.getComponent('last_change').update(TP.date_format(d.last_state_change));
        panel.getComponent('last_notification').update((d.last_notification == 0 ? 'N/A' : TP.date_format(d.last_notification)) + ' (notification '+d.current_notification_number+')');
        if(d.flap_detection_enabled) {
            panel.getComponent('is_flapping').update('<div class="extinfo_noyes_'+d.is_flapping+'">'+ (d.is_flapping ? 'YES' : 'NO') +'<\/div> ('+Number(d.percent_state_change).toFixed(3)+'% state change)');
        } else {
            panel.getComponent('is_flapping').update('N/A');
        }
        if(d.scheduled_downtime_depth==0) {
            panel.getComponent('in_downtime').update('<div class="extinfo_noyes_0">NO<\/div>');
        } else {
            var d = downtimes[0];
            var panelId = panel.id;
            panel.getComponent('in_downtime').update('<div class="extinfo_noyes_1">YES<\/div> ('+TP.date_format(d.start_time)+' - '+TP.date_format(d.end_time)+'<a href="" title="remove downtime" onclick="TP.deleteDowntime(\''+d.id+'\', \''+panel.id+'\', \''+this.type+'\'); return false;"><img src="'+url_prefix+'plugins/panorama/images/remove.png" alt="remove downtime"><\/a>)');
        }
        panel.getComponent('in_check_period').update('<div class="extinfo_yesno_'+d.in_check_period+'">'+ (d.in_check_period>0 ? 'YES' : 'NO') +'<\/div>');
        panel.getComponent('in_notification_period').update('<div class="extinfo_yesno_'+d.in_notification_period+'">'+ (d.in_notification_period>0 ? 'YES' : 'NO') +'<\/div>');
        panel.getComponent('site').update(d.peer_name);
        /* update acknowledged button */
        var toolbar = panel.dockedItems.getAt(0);
        if(d.acknowledged) {
            if(toolbar.items.get('ack')) {
                toolbar.remove(1);
                toolbar.insert(1, new Ext.button.Button({
                    itemId: 'noack',
                    text:   'Remove Ack.',
                    icon:   url_prefix+'plugins/panorama/images/btn_ack_remove.png',
                    menu:    this.type == 'host' ? TP.host_ack_remove_menu() : TP.service_ack_remove_menu()
                }));
            }
        } else {
            if(toolbar.items.get('noack')) {
                toolbar.remove(1);
                toolbar.insert(1, new Ext.button.Button({
                    itemId:  'ack',
                    text:    'Acknowledge',
                    icon:    url_prefix+'plugins/panorama/images/btn_ack.png',
                    menu:     this.type == 'host' ? TP.host_ack_menu() : TP.service_ack_menu(),
                    disabled: d.state == 0 ? true : false
                }));
            } else {
                d.state == 0 ? toolbar.items.get('ack').disable() : toolbar.items.get('ack').enable();
            }
        }
    }
};

TP.ExtinfoPanel = function(type) {
    return {
        xtype:     'panel',
        autoScroll: true,
        border:     false,
        layout: {
            type:   'table',
            columns: 2,
            tableAttrs: {
                width:       '99%',
                cellpadding: '0',
                cellspacing: '1',
                border:      '1',
                bordercolor: '#D0D0D0'
            },
            tdAttrs: {
                valign: 'top'
            }
        },
        defaults: {
            bodyStyle: 'padding: 3px;',
            cls: 'extinfo_val',
            layout: 'fit',
            border: false
        },
        items: [
                { html: 'Current Status' },             { cls: 'extinfo_var', html: '', itemId: 'current_status'  },
                { html: 'Status Information' },         { cls: 'extinfo_var', html: '', itemId: 'status_information' },
                { html: 'Performance Data' },           { cls: 'extinfo_var', html: '', itemId: 'perf_data' },
                { html: 'Current Attempt' },            { cls: 'extinfo_var', html: '', itemId: 'cur_attempt' },
                { html: 'Last Check Time' },            { cls: 'extinfo_var', html: '', itemId: 'last_check_time' },
                { html: 'Check Type' },                 { cls: 'extinfo_var', html: '', itemId: 'check_type' },
                { html: 'Check Latency / Duration' },   { cls: 'extinfo_var', html: '', itemId: 'check_latency' },
                { html: 'Next Scheduled Check' },       { cls: 'extinfo_var', html: '', itemId: 'next_check' },
                { html: 'Last State Change' },          { cls: 'extinfo_var', html: '', itemId: 'last_change' },
                { html: 'Last Notification' },          { cls: 'extinfo_var', html: '', itemId: 'last_notification' },
                { html: 'Is This Service Flapping?' },  { cls: 'extinfo_var', html: '', itemId: 'is_flapping' },
                { html: 'In Scheduled Downtime?' },     { cls: 'extinfo_var', html: '', itemId: 'in_downtime' },
                { html: 'In Check Period?' },           { cls: 'extinfo_var', html: '', itemId: 'in_check_period' },
                { html: 'In Notification Period?' },    { cls: 'extinfo_var', html: '', itemId: 'in_notification_period' },
                { html: 'Monitored by:' },              { cls: 'extinfo_var', html: '', itemId: 'site' }
        ],
        dockedItems: [{
            xtype:  'toolbar',
            dock:   'bottom',
            ui:     'footer',
            defaults: {
                width: 120,
                listeners: {
                    mouseover: function( This, eOpts ) { if(This.menu) { This.menu.letItClose = true  }},
                    mouseout: function(  This, eOpts ) { if(This.menu) { This.menu.letItClose = false }}
                }
            },
            buttonAlign: 'center',
            items: [{
                    /* Add New Downtime */
                    itemId: 'downtime',
                    text:   'Add Downtime',
                    icon:   url_prefix+'plugins/panorama/images/btn_downtime.png',
                    menu:    type == 'host' ? TP.host_downtime_menu() : TP.service_downtime_menu()
                }, {
                    /* Acknowledge */
                    itemId: 'ack',
                    text:   'Acknowledge',
                    icon:   url_prefix+'plugins/panorama/images/btn_ack.png',
                    menu:    type == 'host' ? TP.host_ack_menu() : TP.service_ack_menu()
                }, {
                    /* Reschedule */
                    itemId: 'reschedule',
                    text:   'Reschedule',
                    icon:   url_prefix+'plugins/panorama/images/btn_delay.png',
                    menu:    type == 'host' ? TP.host_reschedule_menu() : TP.service_reschedule_menu()
            }]
        }]
    }
};

TP.ExtinfoPanelLoader = function(scope) {
    return {
        autoLoad: false,
        renderer: 'data',
        scope:    scope,
        ajaxOptions: { method: 'POST' },
        loading:  false,
        listeners: {
            'beforeload': function(This, options, eOpts) {
                if(this.loading) {
                    return false;
                }
                this.loading = true;
                return true;
            }
        },
        callback: TP.updateExtinfoDetails
    };
}


Ext.define('TP.PanletHost', {
    extend: 'TP.Panlet',

    title: 'Host',
    height: 420,
    width:  480,
    menusnr: 0,
    type:   'host',
    initComponent: function() {
        var panel = this;
        this.callParent();
        this.xdata.url         = 'panorama.cgi?task=host_detail';
        if(this.xdata.host    == undefined) { this.xdata.host    = '' }

        /* load host data */
        this.loader = TP.ExtinfoPanelLoader(this),
        this.add(TP.ExtinfoPanel('host'));

        /* auto load when host is set */
        this.addListener('afterrender', function() {
            this.setTitle(this.xdata.host);
            if(this.xdata.host == '') {
                this.gearHandler();
            } else {
                // update must be delayed, IE8 breaks otherwise
                TP.timeouts['timeout_' + this.id + '_refresh'] = window.setTimeout(Ext.bind(this.manualRefresh, this, []), 500);
            }
        });

        this.formUpdatedCallback = function() {
            this.setTitle(this.xdata.host);
        }

        /* should be closeable/moveable all the time because they can be openend even on readonly dashboards */
        this.closable  = true;
        this.draggable = true;
    },
    setGearItems: function() {
        var panel = this;
        this.callParent();
        this.addGearItems(
            TP.objectSearchItem(panel, 'host', 'Hostname')
        );
    }
});

/* form for sending cmd */
TP.ext_menu_command = function(btn_text, cmd_typ, fields, defaults) {
    if(defaults == undefined) { defaults = {} }
    fields.push({ xtype: 'hidden', name: 'json',      value: 1 });
    fields.push({ xtype: 'hidden', name: 'host',      value: '' });
    fields.push({ xtype: 'hidden', name: 'service',   value: '' });
    fields.push({ xtype: 'hidden', name: 'cmd_typ',   value: cmd_typ });
    fields.push({ xtype: 'hidden', name: 'cmd_mod',   value: '2' });
    fields.push({ xtype: 'hidden', name: 'CSRFtoken', value: '' });
    /* this is a Ext.menu.Menu */
    return {
        plain:      true,
        letItClose: false,
        items: [{
            xtype: 'panel',
            items: [{
                xtype:        'form',
                waitMsgTarget: true,
                url:          'cmd.cgi',
                bodyPadding:   3,
                defaults:      defaults,
                items:         fields
            }],
            buttonAlign: 'center',
            buttons: [{
                text:      'Cancel',
                handler:    function() { this.up('menu').letItClose=true; this.up('menu').hide(); },
                pack:      'start'
            }, { xtype: 'tbfill' } ,{
                text:       btn_text,
                formBind:   true,
                handler:    TP.cmd_form_handler
            }]
        }],
        listeners: {
            beforehide: function( This, eOpts ) {
                var panel = This.up('panel').up('panel');
                if(This.letItClose) {
                    panel.menusnr = panel.menusnr - 1;
                    return true;
                }
                return false;
            },
            show: function(This) {
                /* keynav breaks writing spaces */
                This.keyNav.disable();
            },
            beforeshow: function(This, eOpts) {
                /* don't show more than one menu */
                var panel = This.up('panel').up('panel');
                if(panel.menusnr > 0) {
                    return false;
                }
                var form  = This.down('form').getForm();
                var xdata = panel.xdata;
                form.setValues({
                    host:               xdata.host,
                    service:            xdata.service,
                    end_time:           new Date(new Date().getTime()+ downtime_duration *1000),
                    start_time:         new Date(),
                    sticky_ack:         cmd_sticky_ack,
                    send_notification:  cmd_send_notification,
                    persistent:         cmd_persistent,
                    CSRFtoken:          CSRFtoken
                });
                panel.menusnr = panel.menusnr + 1;
                return true;
            }
        }
    }
}
