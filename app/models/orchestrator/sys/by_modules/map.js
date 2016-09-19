
function(doc) {
    if(doc.type === "sys") {
        var i;
        for (i = 0; i < doc.modules.length; i += 1) {
            emit(doc.modules[i], null);
        }
    }
}
