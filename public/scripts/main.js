function filter(exp){
  var elements = document.getElementsByClassName("branch");
  for(var i = 0; i < elements.length; i++){
    var elem = elements[i];
    if(elem.textContent.match(exp)){
      elem.parentNode.style.display = "inherit";
    } else {
      elem.parentNode.style.display = "none";
    }
  }
}
