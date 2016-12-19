/* XXX allow to pass in a 'local' var so the links back into the opac can be localized */
/* maybe also a 'skin' var */

function bbInit(bb) {
	if(!bb) { return; }
    jQuery.ajax({
        url : '/opac/extras/feed/bookbag/atom/' + bb,
        dataType : 'xml'
    }).done(function(data) {
        bbShow(bb, data);
/*
        console.debug('got it for ' + bb);
        console.debug(data);
        jQuery('entry', data).each(function(i, entry) {
            bbShow(bbId, entry);
        });
*/
    });
}

function bbShow(bbId, data) {

	var thisid = bbId;
	bb_total[thisid] = jQuery('entry', data).length;

	//$('bb_name_'+thisid).appendChild(text(jQuery('feed', data).children('title').text()));
	$('bb_name_'+thisid).append(jQuery('feed', data).children('title').text());

	var tbody = $('bbitems_'+thisid);
	
	if(!template[thisid]) 	
		template[thisid] = tbody.removeChild($('row_template_'+thisid));

    jQuery('entry', data).each(function(i, entry) {
		tbody.appendChild(bbShowItem( template[thisid], entry ));
    });
}

function getBibId(item) {
    var id = '';
    jQuery('id', item).each(function(i, val) {
        matches = jQuery(val).text().match(/biblio-record_entry\/([0-9]+)/);
        if (matches == null) return;
        id = matches[1];
    });
    return id;
}

function bbShowItem( template, item ) {
	var row = template.cloneNode(true);
	var tlink = jQuery('a[name=title]', row);
	var alink = jQuery('span[name=author]', row);	
    var bib_id = getBibId(item);

    tlink.append(jQuery('title', item).text());
    tlink.attr('href', bib_id);
    alink.append(jQuery('author', item).text());
		
	return row;
}

jQuery(document).ready(function(){
	for(var i=0;i<bbags.length;i++){
	bb_total[bbags[i]] = 10000000;
		jQuery('#hidden_bb_info').append(
		"<div id='bbitems_"+bbags[i]+"'><div id='row_template_"+bbags[i]+"' class='bbitem_"+bbags[i]+"'><a href='#' name='title' class='bbtitle_"+bbags[i]+"'> </a><span name='author'> </span></div></div>");
		jQuery('#carousels').append(
		"<div><div id='bb_name_"+bbags[i]+"' class='carousel_title'> </div><div class='wrap'>  <ul id='mycarousel_"+bbags[i]+"' class='jcarousel-skin-meskin'>  </ul></div></div>");
		
		bbInit(bbags[i]);
	}
});
