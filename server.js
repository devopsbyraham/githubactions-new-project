const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/health', (req, res) => {
  res.status(200).json({ status: 'Healthy', version: process.env.GITHUB_SHA || 'local' });
});

app.get('/', (req, res) => {
  res.send('<h1>GitHub Actions to AWS ECS Deployment Successful!</h1>');
});

const server = app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
module.exports = server;
