
function(doc) {
    if(doc.type === "mod") {
        emit(doc.edge_id, null);
    }
}
