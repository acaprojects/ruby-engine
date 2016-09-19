
function(doc) {
    if(doc.type === "mod") {
        emit(doc.role, null);
    }
}
