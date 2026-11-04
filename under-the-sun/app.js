const items = document.querySelectorAll("[data-reveal]");

if ("IntersectionObserver" in window && items.length) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          entry.target.classList.add("is-visible");
          observer.unobserve(entry.target);
        }
      }
    },
    { rootMargin: "0px 0px -12% 0px", threshold: 0.08 }
  );
  items.forEach((item) => observer.observe(item));
} else {
  items.forEach((item) => item.classList.add("is-visible"));
}

// 让 FAQ 一次只展开一个，避免页面跳动
const details = Array.from(document.querySelectorAll(".faq details"));
for (const node of details) {
  node.addEventListener("toggle", () => {
    if (!node.open) return;
    for (const other of details) {
      if (other !== node) other.open = false;
    }
  });
}
