
function(doc, meta) {
    if(doc.type === "edge") {
        emit(meta.master_id, null);
    }
}
