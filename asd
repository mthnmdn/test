#!/usr/bin/env python3
import grpc
import helloworld_pb2
import helloworld_pb2_grpc

def main():
    target = "grpc-helloworld.grpc-demo.svc.cluster.local:50051"

    # Tek channel = tek bağlantı havuzu / aynı HTTP/2 connection'ın yeniden kullanılması
    channel = grpc.insecure_channel(target)

    # Stub'ı bir kez oluşturup tekrar kullanıyoruz
    stub = helloworld_pb2_grpc.GreeterStub(channel)

    try:
        for name in ["Mete", "Emre", "Ali", "Veli"]:
            response = stub.SayHello(
                helloworld_pb2.HelloRequest(name=name)
            )
            print(response.message)
    finally:
        channel.close()

if __name__ == "__main__":
    main()
