
function(doc) {
    if(doc.type === "trig") {
        emit(doc.control_system_id, null);
    }
}
