FROM python:3.12-alpine
RUN adduser -D -u 65532 -g 65532 ridgepost
WORKDIR /app
COPY server.py /app/server.py
USER 65532
EXPOSE 8080
ENV PORT=8080
CMD ["python", "/app/server.py"]
