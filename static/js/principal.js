// Menú de navegación para dispositivos móviles.
// (La consulta de estadísticas ahora vive en panel.js)

document.addEventListener("DOMContentLoaded", function () {

    const toggle = document.getElementById("navbarToggle");
    const links = document.getElementById("navbarLinks");

    if (toggle && links) {
        toggle.addEventListener("click", function () {
            links.classList.toggle("active");

            const abierto = links.classList.contains("active");
            toggle.setAttribute("aria-expanded", abierto);
        });

        links.querySelectorAll("a").forEach(function (link) {
            link.addEventListener("click", function () {
                links.classList.remove("active");
                toggle.setAttribute("aria-expanded", "false");
            });
        });
    }

});
