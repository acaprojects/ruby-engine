
function(doc) {
    if(doc.type === "trig") {
        emit(doc.trigger_id, null);
    }
}
