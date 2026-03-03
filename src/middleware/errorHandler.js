/**
 * Express error-handling middleware.
 * Must be registered after all routes.
 */
export function errorHandler(err, req, res, _next) {
  console.error(`[${req.method} ${req.path}]`, err);

  if (err.name === 'ZodError') {
    return res.status(400).json({
      error: 'Validation error',
      details: err.errors,
    });
  }

  const status = err.status || err.statusCode || 500;
  res.status(status).json({
    error: err.message || 'Internal server error',
  });
}
