// Live search for tables: <input data-filter="#table-id">
document.querySelectorAll('[data-filter]').forEach(function (input) {
  var table = document.querySelector(input.dataset.filter);
  input.addEventListener('input', function () {
    var q = input.value.toLowerCase();
    table.querySelectorAll('tbody tr').forEach(function (tr) { tr.hidden = !tr.textContent.toLowerCase().includes(q); });
  });
});

// Confirm before destructive actions: <form data-confirm="Are you sure?">
document.querySelectorAll('form[data-confirm]').forEach(function (f) {
  f.addEventListener('submit', function (e) { if (!confirm(f.dataset.confirm)) e.preventDefault(); });
});

// Stop double submits, and show that something is happening
document.querySelectorAll('form').forEach(function (f) {
  f.addEventListener('submit', function (e) {
    if (e.defaultPrevented) return;
    f.querySelectorAll('button[type=submit]').forEach(function (b) {
      setTimeout(function () { b.disabled = true; if (f.dataset.busy) b.textContent = f.dataset.busy; }, 0);
    });
  });
});

document.querySelectorAll('.flash button').forEach(function (b) {
  b.addEventListener('click', function () { b.parentElement.remove(); });
});

// Sales form: show sellable stock and list price for the chosen product
var sel = document.querySelector('#sale-product');
if (sel) {
  var hint = document.querySelector('#sale-hint'), price = document.querySelector('#sale-price');
  var update = function () {
    var o = sel.selectedOptions[0];
    if (!o || !o.value) { hint.textContent = ''; price.placeholder = 'List price'; return; }
    hint.textContent = o.dataset.sellable + ' units can be sold now. List price ₹' + o.dataset.price + '.';
    price.placeholder = o.dataset.price;
  };
  sel.addEventListener('change', update); update();
}
