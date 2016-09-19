
function(doc) {
    if(doc.type === "mod" && doc.dependency_id) {
        emit(doc.dependency_id, null);
    }
}
