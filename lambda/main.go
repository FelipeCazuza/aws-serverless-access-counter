package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strconv"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

var (
	tableName string
	ddbClient counterClient
)

type counterClient interface {
	UpdateItem(context.Context, *dynamodb.UpdateItemInput, ...func(*dynamodb.Options)) (*dynamodb.UpdateItemOutput, error)
}

func handler(ctx context.Context, request events.APIGatewayV2HTTPRequest) (events.APIGatewayV2HTTPResponse, error) {
	if request.RequestContext.HTTP.Method != "POST" {
		return jsonResponse(405, map[string]string{
			"error": "method not allowed",
		})
	}

	result, err := ddbClient.UpdateItem(ctx, &dynamodb.UpdateItemInput{
		TableName: aws.String(tableName),
		Key: map[string]types.AttributeValue{
			"id": &types.AttributeValueMemberS{
				Value: "hits",
			},
		},
		UpdateExpression: aws.String("ADD hits :increment"),
		ExpressionAttributeValues: map[string]types.AttributeValue{
			":increment": &types.AttributeValueMemberN{
				Value: "1",
			},
		},
		ReturnValues: types.ReturnValueUpdatedNew,
	})
	if err != nil {
		log.Printf("dynamodb UpdateItem failed: %v", err)
		return jsonResponse(500, map[string]string{
			"error": "internal server error",
		})
	}

	numberValue, ok := result.Attributes["hits"].(*types.AttributeValueMemberN)
	if !ok {
		log.Printf("DynamoDB response did not contain numeric hits")
		return jsonResponse(500, map[string]string{
			"error": "internal server error",
		})
	}

	hits, err := strconv.ParseInt(numberValue.Value, 10, 64)
	if err != nil {
		log.Printf("unable to parse hits value: %v", err)
		return jsonResponse(500, map[string]string{
			"error": "internal server error",
		})
	}

	return jsonResponse(200, map[string]int64{"hits": hits})
}

func jsonResponse(statusCode int, body any) (events.APIGatewayV2HTTPResponse, error) {
	payload, err := json.Marshal(body)
	if err != nil {
		return events.APIGatewayV2HTTPResponse{}, err
	}

	return events.APIGatewayV2HTTPResponse{
		StatusCode: statusCode,
		Headers: map[string]string{
			"content-type": "application/json",
		},
		Body: string(payload),
	}, nil
}

func main() {
	tableName = os.Getenv("TABLE_NAME")
	if tableName == "" {
		log.Fatal("TABLE_NAME environment variable is required")
	}

	cfg, err := config.LoadDefaultConfig(context.Background())
	if err != nil {
		log.Fatalf("unable to load AWS SDK configuration: %v", err)
	}

	ddbClient = dynamodb.NewFromConfig(cfg)
	lambda.Start(handler)
}
