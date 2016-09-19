
function(doc) {
    if(doc.type === "user") {
        emit(doc.sys_admin, null);
    }
}
