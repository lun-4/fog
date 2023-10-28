package main

import (
	"github.com/gofiber/fiber/v2"
	"log"
)
import "os"

func main() {
	// TODO should not truncate log.txt i think
	file, err := os.Create("log.txt")
	defer file.Close()
	if err != nil {
		log.Fatal(err)
	}

	log.Print("aakdjf")

	app := fiber.New()

	app.Post("/log", func(c *fiber.Ctx) error {
		file.Write(c.Body())
		file.Write([]byte{'\n'})
		file.Sync()

		return c.SendStatus(204)

	})

	log.Fatal(app.Listen(":9741"))

}
