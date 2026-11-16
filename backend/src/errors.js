/** Carry only an intentionally public error; internal exceptions are never sent to clients. */
export class HttpError extends Error {
  constructor(status, detail) {
    super(detail);
    this.statusCode = status;
  }
}
