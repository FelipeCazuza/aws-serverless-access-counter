package main

import (
	"context"
	"errors"
	"testing"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb"
	"github.com/aws/aws-sdk-go-v2/service/dynamodb/types"
)

type fakeCounter struct {
	call func(context.Context, *dynamodb.UpdateItemInput) (*dynamodb.UpdateItemOutput, error)
}

func (f fakeCounter) UpdateItem(ctx context.Context, in *dynamodb.UpdateItemInput, _ ...func(*dynamodb.Options)) (*dynamodb.UpdateItemOutput, error) {
	return f.call(ctx, in)
}

func TestHandler(t *testing.T) {
	for _, tc := range []struct {
		name   string
		method string
		value  types.AttributeValue
		err    error
		status int
		body   string
	}{
		{"increment", "POST", &types.AttributeValueMemberN{Value: "2"}, nil, 200, `{"hits":2}`},
		{"method", "GET", nil, nil, 405, `{"error":"method not allowed"}`},
		{"service error", "POST", nil, errors.New("unavailable"), 500, `{"error":"internal server error"}`},
		{"missing", "POST", nil, nil, 500, `{"error":"internal server error"}`},
		{"wrong type", "POST", &types.AttributeValueMemberS{Value: "2"}, nil, 500, `{"error":"internal server error"}`},
		{"invalid number", "POST", &types.AttributeValueMemberN{Value: "1.5"}, nil, 500, `{"error":"internal server error"}`},
		{"overflow", "POST", &types.AttributeValueMemberN{Value: "9223372036854775808"}, nil, 500, `{"error":"internal server error"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			tableName = "test-table"
			called := false
			ddbClient = fakeCounter{call: func(got context.Context, in *dynamodb.UpdateItemInput) (*dynamodb.UpdateItemOutput, error) {
				called = true
				if got != ctx || *in.TableName != tableName || *in.UpdateExpression != "ADD hits :increment" || in.ReturnValues != types.ReturnValueUpdatedNew {
					t.Fatal("incorrect context or atomic update")
				}
				if in.Key["id"].(*types.AttributeValueMemberS).Value != "hits" || in.ExpressionAttributeValues[":increment"].(*types.AttributeValueMemberN).Value != "1" {
					t.Fatal("incorrect key or increment")
				}
				attrs := map[string]types.AttributeValue{}
				if tc.value != nil {
					attrs["hits"] = tc.value
				}
				return &dynamodb.UpdateItemOutput{Attributes: attrs}, tc.err
			}}
			req := events.APIGatewayV2HTTPRequest{}
			req.RequestContext.HTTP.Method = tc.method
			response, err := handler(ctx, req)
			if err != nil || response.StatusCode != tc.status || response.Body != tc.body || response.Headers["content-type"] != "application/json" {
				t.Fatalf("response = %+v, error = %v", response, err)
			}
			if called != (tc.method == "POST") {
				t.Fatal("unexpected DynamoDB call")
			}
		})
	}
}
