
function(doc) {
    if(doc.type === "sys") {
        var i;
        for (i = 0; i < doc.zones.length; i++) {
            emit(doc.zones[i], null);
        }
    }
}
