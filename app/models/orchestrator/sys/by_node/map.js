
function(doc) {
    if(doc.type === "sys") {
        emit(doc.edge_id, null);
    }
}
