
function(doc, meta) {
    if(doc.type === "zone") {
        emit(meta.id, null);
    }
}
