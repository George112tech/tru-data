// Builds tailwind.css from the classes used in index.html.
// Rebuild after adding new Tailwind classes:  npm install && npm run build:css
module.exports = {
  content: ['./index.html'],
  theme: { extend: {} },
  plugins: [],
};
